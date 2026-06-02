// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title KaskadPriceOracle
/// @notice TEE-backed price oracle. Enclave signers register via
///         `registerEnclave(attestationDoc)`: a valid Nitro attestation
///         matching `expectedPCR0` is required AND the call is `onlyOwner`
///         (dual gate — closes the seal-and-leak vector where an attacker
///         running identical-PCR infrastructure self-registers). The
///         owner cannot whitelist a signer without a valid attestation;
///         attestation alone is not sufficient. `removeSigner` is
///         `onlyOwner` for emergency revocation. Quorum + price logic is
///         unchanged.
contract KaskadPriceOracle is Ownable2Step {
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

    /// @notice Per-asset quorum. Struct kept for future extensions.
    struct AssetParams {
        uint8 minSources;
    }

    // ─── Immutable Config ────────────────────────────────────────────────

    /// @notice PCR0 the enclave attestation must match. Pinned at deploy.
    bytes32 public immutable expectedPCR0;

    /// @notice On-chain attestation verifier (Nitro CBOR/COSE/P-384 path).
    IAttestationVerifier public immutable verifier;

    // ─── Constants ───────────────────────────────────────────────────────

    uint8  public constant DECIMALS = 8;
    uint16 public constant MAX_PRICE_CHANGE_BPS = 1500; // 15% regular cap
    uint16 public constant MAX_RESUME_CHANGE_BPS = 3000; // loosened cap after silence
    uint256 public constant CIRCUIT_BREAKER_STALENESS = 4 hours;

    /// @notice Reject signed updates whose enclave-authoritative timestamp
    ///         runs > 2h ahead of `block.timestamp`. Wide cap absorbs Kasplex
    ///         L2 clock drift while still blocking far-future poison.
    uint256 public constant MAX_FUTURE_SKEW = 2 hours;

    /// @notice Hard cap on assets per `registerAssets` call. Wipe loop is
    ///         bounded; compromised owner cannot DoS via 5000-entry preload.
    ///         Realistic Aave V3 asset counts are 15-25.
    uint256 public constant MAX_ASSETS = 32;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice Whitelist of enclave-signing addresses. Populated by
    ///         `registerEnclave` (attestation + onlyOwner). A signed price
    ///         update is accepted iff the recovered ECDSA address is in
    ///         this set. There is no direct `addSigner` — every signer
    ///         must trace back to a verified attestation.
    mapping(address => bool) public validSigner;

    /// @notice Count of `validSigner` members. Gates `registerAssets` and
    ///         is exposed for off-chain oracle-ready checks.
    uint256 public signerCount;

    mapping(bytes32 => PriceData) public latestPrices;
    mapping(bytes32 => mapping(uint80 => PriceData)) public priceHistory;
    mapping(bytes32 => uint80) public currentRound;

    /// @notice Per-asset quorum, keyed by keccak256(symbol). `minSources == 0`
    ///         means asset NOT registered and `updatePrice` reverts.
    mapping(bytes32 => AssetParams) public assetParams;

    /// @notice Ordered list of currently-registered asset ids.
    bytes32[] private _registeredAssetIds;

    // ─── Events ──────────────────────────────────────────────────────────

    event EnclaveRegistered(address indexed signer, bytes32 pcr0, uint256 timestamp);
    event SignerRemoved(address indexed signer);
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
    error InvalidSignature();
    error StalePrice(uint256 provided, uint256 current);
    error NoEnclaveRegistered();
    error InsufficientSources();
    error PriceChangeExceedsLimit(uint256 changeBps, uint256 maxBps);
    error NoPriceData(bytes32 assetId);
    error AssetNotRegistered(bytes32 assetId);
    error AssetsUnsorted();
    error AssetsEmpty();
    error MismatchedLengths();
    error InvalidMinSources();
    error ZeroAddress();
    error SignerNotRegistered(address signer);
    error FutureTimestamp(uint256 provided, uint256 maxAllowed);
    error TooManyAssets(uint256 provided, uint256 max);
    error NoRoundData(bytes32 assetId, uint80 roundId);

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(bytes32 _expectedPCR0, address _verifier, address initialOwner)
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (_verifier == address(0)) revert ZeroAddress();
        expectedPCR0 = _expectedPCR0;
        verifier = IAttestationVerifier(_verifier);
    }

    // ─── Enclave Registration (dual gate: attestation + owner) ───────────

    /// @notice Register an enclave signer derived from a valid Nitro
    ///         attestation. Two gates apply:
    ///           (1) Attestation must verify on-chain and PCR0 must match
    ///               the immutable `expectedPCR0`.
    ///           (2) Caller must be the owner — closes seal-and-leak where
    ///               a same-PCR attacker (e.g. identical EIF on their own
    ///               AWS account without locked KMS) would otherwise add
    ///               their own signer.
    ///         Grow-only: re-registering an already-whitelisted signer
    ///         is a no-op (no event, no count bump).
    function registerEnclave(bytes calldata attestationDoc) external onlyOwner {
        (bool valid, bytes32 pcr0, address enclaveAddress) =
            verifier.verifyAttestation(attestationDoc);

        if (!valid) revert InvalidAttestation();
        if (pcr0 != expectedPCR0) revert PCR0Mismatch(pcr0, expectedPCR0);

        if (!validSigner[enclaveAddress]) {
            validSigner[enclaveAddress] = true;
            signerCount += 1;
            emit EnclaveRegistered(enclaveAddress, pcr0, block.timestamp);
        }
    }

    /// @notice Revoke a previously-whitelisted signer. Emergency lever
    ///         for decommissioned enclaves and key compromise. No
    ///         attestation needed — subtractive operations are safe
    ///         under the owner-trust model.
    function removeSigner(address signer) external onlyOwner {
        if (!validSigner[signer]) revert SignerNotRegistered(signer);
        delete validSigner[signer];
        signerCount -= 1;
        emit SignerRemoved(signer);
    }

    // ─── Asset-quorum registration (owner) ───────────────────────────────

    /// @notice Write the per-asset quorum commitment. `ids` MUST be
    ///         strictly ascending (canonical order, no duplicates).
    function registerAssets(
        bytes32[] calldata ids,
        uint8[] calldata minSources
    ) external onlyOwner {
        if (signerCount == 0) revert NoEnclaveRegistered();
        if (ids.length == 0) revert AssetsEmpty();
        if (ids.length > MAX_ASSETS) revert TooManyAssets(ids.length, MAX_ASSETS);
        if (ids.length != minSources.length) revert MismatchedLengths();

        uint256 oldLen = _registeredAssetIds.length;
        for (uint256 i = 0; i < oldLen; i++) {
            delete assetParams[_registeredAssetIds[i]];
        }
        delete _registeredAssetIds;

        for (uint256 i = 0; i < ids.length; i++) {
            if (i > 0 && ids[i] <= ids[i - 1]) revert AssetsUnsorted();
            if (minSources[i] == 0) revert InvalidMinSources();
            assetParams[ids[i]] = AssetParams({minSources: minSources[i]});
            _registeredAssetIds.push(ids[i]);
        }

        emit AssetsRegistered(msg.sender, ids.length);
    }

    function registeredAssetIds() external view returns (bytes32[] memory) {
        return _registeredAssetIds;
    }

    // ─── Core: Price Update ──────────────────────────────────────────────

    function updatePrice(
        bytes32 assetId,
        uint256 price,
        uint256 timestamp,
        uint8   numSources,
        bytes32 sourcesHash,
        bytes calldata signature
    ) external {
        if (signerCount == 0) revert NoEnclaveRegistered();

        uint8 minReq = assetParams[assetId].minSources;
        if (minReq == 0) revert AssetNotRegistered(assetId);
        if (numSources < minReq) revert InsufficientSources();

        _checkFreshnessAndBreaker(assetId, price, timestamp);
        _verifyPriceSignature(assetId, price, timestamp, numSources, sourcesHash, signature);
        _storePriceUpdate(assetId, price, timestamp, numSources, sourcesHash);
    }

    // ─── updatePrice internals ───────────────────────────────────────────

    function _checkFreshnessAndBreaker(
        bytes32 assetId,
        uint256 price,
        uint256 timestamp
    ) internal view {
        PriceData storage current = latestPrices[assetId];

        uint256 maxAllowed = block.timestamp + MAX_FUTURE_SKEW;
        if (timestamp > maxAllowed) revert FutureTimestamp(timestamp, maxAllowed);

        if (current.signedTimestamp > 0 && timestamp <= current.signedTimestamp) {
            revert StalePrice(timestamp, current.signedTimestamp);
        }

        if (current.price == 0) return;

        uint16 limit = MAX_PRICE_CHANGE_BPS;
        if (block.timestamp - current.timestamp >= CIRCUIT_BREAKER_STALENESS) {
            limit = MAX_RESUME_CHANGE_BPS;
        }

        uint256 changeBps;
        if (price > current.price) {
            changeBps = ((price - current.price) * 10000) / current.price;
        } else {
            changeBps = ((current.price - price) * 10000) / current.price;
        }
        if (changeBps > limit) revert PriceChangeExceedsLimit(changeBps, limit);
    }

    /// @dev EIP-191 over abi.encodePacked(assetId,price,ts,nSrc,srcHash);
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

/// @title IAttestationVerifier
/// @notice Interface for TEE attestation verification.
interface IAttestationVerifier {
    function verifyAttestation(bytes calldata attestationDoc)
        external
        view
        returns (bool valid, bytes32 pcr0, address enclaveAddress);
}
