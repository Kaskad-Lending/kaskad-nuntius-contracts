// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IAttestationVerifier} from "./IAttestationVerifier.sol";

/// @title KaskadPriceOracleV2
/// @notice TEE-backed price oracle. A signer enters only through
///         `registerEnclave`, which needs both a Nitro attestation matching
///         `expectedPcr0` and the owner's signature. Against V1: PCR0 is
///         owner-settable so a new enclave image no longer forces a redeploy,
///         and the circuit-breaker bounds are per asset.
contract KaskadPriceOracleV2 is Ownable2Step {
    using MessageHashUtils for bytes32;

    // ─── Types ───────────────────────────────────────────────────────────

    struct PriceData {
        uint256 price;           // fixed-point, 8 decimals
        uint256 timestamp;       // block.timestamp at update (Aave staleness)
        uint256 signedTimestamp; // enclave exchange-server timestamp (replay/order)
        uint8   numSources;
        bytes32 sourcesHash;     // keccak256 commitment of source data
        uint80  roundId;
    }

    /// @notice Per-asset quorum and circuit-breaker bounds. `minSources == 0`
    ///         means the asset is not registered.
    struct AssetParams {
        uint8  minSources;
        uint16 maxChangeBps;
        uint16 maxResumeChangeBps;
    }

    /// @notice One `registerAssets` entry. Kept as a struct so the four fields
    ///         cannot desync across parallel arrays.
    struct AssetConfig {
        bytes32 id;
        uint8   minSources;
        uint16  maxChangeBps;
        uint16  maxResumeChangeBps;
    }

    // ─── Immutable config ────────────────────────────────────────────────

    /// @notice On-chain attestation verifier. Immutable on purpose: an owner who
    ///         could swap it could return any address as attested.
    IAttestationVerifier public immutable verifier;

    // ─── Constants ───────────────────────────────────────────────────────

    uint8  public constant DECIMALS = 8;

    /// @notice Window of silence after which an asset's `maxResumeChangeBps`
    ///         replaces its `maxChangeBps`. Pull-mode feeds lag both quiet
    ///         markets and real dislocations; without the relax, a feed stays
    ///         frozen after every outage.
    uint256 public constant CIRCUIT_BREAKER_STALENESS = 1 hours;

    /// @notice Ceiling on either per-asset bound, so the owner cannot disable
    ///         the breaker outright.
    uint16 public constant MAX_CHANGE_BPS_CEILING = 5000;

    /// @notice Reject signed updates running further ahead of `block.timestamp`
    ///         than this. Wide enough for L2 clock drift, short of poison.
    uint256 public constant MAX_FUTURE_SKEW = 2 hours;

    /// @notice Hard cap per `registerAssets` call; the wipe loop is bounded.
    uint256 public constant MAX_ASSETS = 32;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice Enclave measurement `registerEnclave` pins against. Settable so a
    ///         rebuilt image does not force a new oracle.
    bytes32 public expectedPcr0;

    /// @notice Enclave-signing addresses. A price update is accepted iff the
    ///         recovered address is in this set; there is no direct `addSigner`.
    mapping(address => bool) public validSigner;

    /// @notice Members of `validSigner`. Gates `registerAssets` and is read
    ///         off-chain for oracle-ready checks.
    uint256 public signerCount;

    mapping(bytes32 => PriceData) public latestPrices;
    mapping(bytes32 => mapping(uint80 => PriceData)) public priceHistory;
    mapping(bytes32 => uint80) public currentRound;

    /// @notice Per-asset params, keyed by keccak256(symbol).
    mapping(bytes32 => AssetParams) public assetParams;

    /// @notice Ordered list of currently-registered asset ids.
    bytes32[] private _registeredAssetIds;

    // ─── Events ──────────────────────────────────────────────────────────

    event EnclaveRegistered(address indexed signer, bytes32 pcr0, uint256 timestamp);
    event SignerRemoved(address indexed signer);
    event ExpectedPcr0Set(bytes32 pcr0);
    event PriceUpdated(
        bytes32 indexed assetId,
        uint256 price,
        uint256 timestamp,
        uint8   numSources,
        uint80  roundId
    );
    event AssetsRegistered(address indexed owner, uint256 numAssets);

    // ─── Errors ──────────────────────────────────────────────────────────

    error InvalidAttestation();
    error PCR0Mismatch(bytes32 provided, bytes32 expected);
    error ZeroPCR0();
    error InvalidSignature();
    error StalePrice(uint256 provided, uint256 current);
    error NoEnclaveRegistered();
    error InsufficientSources();
    error PriceChangeExceedsLimit(uint256 changeBps, uint256 maxBps);
    error NoPriceData(bytes32 assetId);
    error AssetNotRegistered(bytes32 assetId);
    error AssetsUnsorted();
    error AssetsEmpty();
    error InvalidMinSources();
    error InvalidChangeBps(uint16 maxChangeBps, uint16 maxResumeChangeBps);
    error ZeroAddress();
    error ZeroPrice();
    error SignerNotRegistered(address signer);
    error FutureTimestamp(uint256 provided, uint256 maxAllowed);
    error TooManyAssets(uint256 provided, uint256 max);
    error NoRoundData(bytes32 assetId, uint80 roundId);

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(bytes32 _expectedPcr0, address _verifier, address initialOwner)
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (_verifier == address(0)) revert ZeroAddress();
        if (_expectedPcr0 == bytes32(0)) revert ZeroPCR0();
        expectedPcr0 = _expectedPcr0;
        verifier = IAttestationVerifier(_verifier);
        emit ExpectedPcr0Set(_expectedPcr0);
    }

    // ─── Enclave registration (attestation + owner) ──────────────────────

    /// @notice Admit the signer of a valid attestation whose PCR0 matches
    ///         `expectedPcr0`. Owner-gated as well, so an attacker running an
    ///         identical image on their own account cannot self-register.
    ///         Re-registering a known signer is a no-op.
    function registerEnclave(bytes calldata attestationDoc) external onlyOwner {
        (bool valid, bytes32 pcr0, address enclaveAddress) =
            verifier.verifyAttestation(attestationDoc);

        if (!valid) revert InvalidAttestation();
        if (pcr0 != expectedPcr0) revert PCR0Mismatch(pcr0, expectedPcr0);

        if (!validSigner[enclaveAddress]) {
            validSigner[enclaveAddress] = true;
            signerCount += 1;
            emit EnclaveRegistered(enclaveAddress, pcr0, block.timestamp);
        }
    }

    /// @notice Revoke a signer. Emergency lever for a decommissioned enclave or
    ///         a key compromise; subtraction is safe under the owner-trust model.
    function removeSigner(address signer) external onlyOwner {
        if (!validSigner[signer]) revert SignerNotRegistered(signer);
        delete validSigner[signer];
        signerCount -= 1;
        emit SignerRemoved(signer);
    }

    /// @notice Accept a new enclave image. Signers admitted under the previous
    ///         PCR0 stay valid until removed, so a rotation can overlap.
    function setExpectedPcr0(bytes32 pcr0) external onlyOwner {
        if (pcr0 == bytes32(0)) revert ZeroPCR0();
        expectedPcr0 = pcr0;
        emit ExpectedPcr0Set(pcr0);
    }

    // ─── Asset registration (owner) ──────────────────────────────────────

    /// @notice Replace the registered asset set. `configs` MUST be strictly
    ///         ascending by `id` (canonical order, no duplicates).
    function registerAssets(AssetConfig[] calldata configs) external onlyOwner {
        if (signerCount == 0) revert NoEnclaveRegistered();
        if (configs.length == 0) revert AssetsEmpty();
        if (configs.length > MAX_ASSETS) revert TooManyAssets(configs.length, MAX_ASSETS);

        uint256 oldLen = _registeredAssetIds.length;
        for (uint256 i = 0; i < oldLen; i++) {
            delete assetParams[_registeredAssetIds[i]];
        }
        delete _registeredAssetIds;

        for (uint256 i = 0; i < configs.length; i++) {
            AssetConfig calldata c = configs[i];
            if (i > 0 && c.id <= configs[i - 1].id) revert AssetsUnsorted();
            if (c.minSources == 0) revert InvalidMinSources();
            if (
                c.maxChangeBps == 0
                    || c.maxResumeChangeBps < c.maxChangeBps
                    || c.maxResumeChangeBps > MAX_CHANGE_BPS_CEILING
            ) {
                revert InvalidChangeBps(c.maxChangeBps, c.maxResumeChangeBps);
            }
            assetParams[c.id] = AssetParams({
                minSources: c.minSources,
                maxChangeBps: c.maxChangeBps,
                maxResumeChangeBps: c.maxResumeChangeBps
            });
            _registeredAssetIds.push(c.id);
        }

        emit AssetsRegistered(msg.sender, configs.length);
    }

    function registeredAssetIds() external view returns (bytes32[] memory) {
        return _registeredAssetIds;
    }

    // ─── Core: price update ──────────────────────────────────────────────

    function updatePrice(
        bytes32 assetId,
        uint256 price,
        uint256 timestamp,
        uint8   numSources,
        bytes32 sourcesHash,
        bytes calldata signature
    ) external {
        if (signerCount == 0) revert NoEnclaveRegistered();
        if (price == 0) revert ZeroPrice();

        AssetParams storage params = assetParams[assetId];
        if (params.minSources == 0) revert AssetNotRegistered(assetId);
        if (numSources < params.minSources) revert InsufficientSources();

        _checkFreshnessAndBreaker(assetId, price, timestamp, params);
        _verifyPriceSignature(assetId, price, timestamp, numSources, sourcesHash, signature);
        _storePriceUpdate(assetId, price, timestamp, numSources, sourcesHash);
    }

    // ─── updatePrice internals ───────────────────────────────────────────

    function _checkFreshnessAndBreaker(
        bytes32 assetId,
        uint256 price,
        uint256 timestamp,
        AssetParams storage params
    ) internal view {
        PriceData storage current = latestPrices[assetId];

        uint256 maxAllowed = block.timestamp + MAX_FUTURE_SKEW;
        if (timestamp > maxAllowed) revert FutureTimestamp(timestamp, maxAllowed);

        if (current.signedTimestamp > 0 && timestamp <= current.signedTimestamp) {
            revert StalePrice(timestamp, current.signedTimestamp);
        }

        if (current.price == 0) return;

        uint16 limit = params.maxChangeBps;
        if (block.timestamp - current.timestamp >= CIRCUIT_BREAKER_STALENESS) {
            limit = params.maxResumeChangeBps;
        }

        uint256 changeBps;
        if (price > current.price) {
            changeBps = ((price - current.price) * 10000) / current.price;
        } else {
            changeBps = ((current.price - price) * 10000) / current.price;
        }
        if (changeBps > limit) revert PriceChangeExceedsLimit(changeBps, limit);
    }

    /// @dev EIP-191 over abi.encodePacked(assetId,price,ts,nSrc,srcHash); the
    ///      recovered address must be in `validSigner`.
    function _verifyPriceSignature(
        bytes32 assetId,
        uint256 price,
        uint256 timestamp,
        uint8 numSources,
        bytes32 sourcesHash,
        bytes calldata signature
    ) internal view {
        bytes32 messageHash = keccak256(
            abi.encodePacked(assetId, price, timestamp, numSources, sourcesHash)
        );
        address recovered = ECDSA.recover(messageHash.toEthSignedMessageHash(), signature);
        if (!validSigner[recovered]) revert InvalidSignature();
    }

    function _storePriceUpdate(
        bytes32 assetId,
        uint256 price,
        uint256 timestamp,
        uint8 numSources,
        bytes32 sourcesHash
    ) internal {
        uint80 newRound = currentRound[assetId] + 1;

        PriceData storage stored = latestPrices[assetId];
        stored.price = price;
        stored.timestamp = block.timestamp;
        stored.signedTimestamp = timestamp;
        stored.numSources = numSources;
        stored.sourcesHash = sourcesHash;
        stored.roundId = newRound;

        priceHistory[assetId][newRound] = stored;
        currentRound[assetId] = newRound;

        emit PriceUpdated(assetId, price, timestamp, numSources, newRound);
    }

    // ─── Reads ───────────────────────────────────────────────────────────

    function getLatestPrice(bytes32 assetId)
        external
        view
        returns (uint256 price, uint256 timestamp, uint8 numSources, uint80 roundId)
    {
        PriceData storage data = latestPrices[assetId];
        if (data.timestamp == 0) revert NoPriceData(assetId);
        return (data.price, data.timestamp, data.numSources, data.roundId);
    }

    function getRoundData(bytes32 assetId, uint80 roundId)
        external
        view
        returns (uint256 price, uint256 timestamp, uint8 numSources)
    {
        PriceData storage data = priceHistory[assetId][roundId];
        if (data.timestamp == 0) revert NoRoundData(assetId, roundId);
        return (data.price, data.timestamp, data.numSources);
    }

    function isValidSigner(address who) external view returns (bool) {
        return validSigner[who];
    }
}
