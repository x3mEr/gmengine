// deployPrice, autoDeployPricePerDay, collector, relayer
// 1.2 SOMI,  1.5 SOMI
// 1200000000000000000, 1500000000000000000, 0xcc433247d87bf92b4e36cf923f02d42e1e1466fb, 0xd42940c98F5B8E31B18D5c2F5d8C349d56b96BE1
// 0.00012, 0.00015
// 120000000000000, 150000000000000, 0xcc433247d87bf92b4e36cf923f02d42e1e1466fb, 0xd42940c98F5B8E31B18D5c2F5d8C349d56b96BE1

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MinimalContract.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title DeployFactory
 * @notice On-chain daily contract deployment tracker with AutoDeploy relay support via EIP-712.
 *         Tracks per-user deploy streaks, total deploy count, and supports paid Deploy + AutoDeploy subscriptions.
 *         Each deployment creates a MinimalContract owned by the user.
 *         Designed for multi-chain deployment — each chain has its own independent instance.
 */
contract AutoDeployFactory {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ---------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------

    struct DeployData {
        uint256 lastDeployDay; // day number (block.timestamp / 86400)
        uint256 streak;        // current consecutive-day streak
        uint256 totalDeploys;  // lifetime deploy count
    }

    // ---------------------------------------------------------------
    // Constants — EIP-712
    // ---------------------------------------------------------------

    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 public constant AUTODEPLOY_TYPEHASH =
        keccak256("AutoDeployAuth(address user,uint256 nonce,uint256 deadline)");

    string public constant NAME    = "AutoDeploy";
    string public constant VERSION = "1";

    // ---------------------------------------------------------------
    // State
    // ---------------------------------------------------------------

    address public owner;
    address public pendingOwner;
    address payable public collector;
    address payable public relayer;

    bytes32 public immutable DOMAIN_SEPARATOR;

    uint256 public deployPrice;           // wei required for deploySelf()
    uint256 public autoDeployPricePerDay; // wei per day for AutoDeploy subscription

    mapping(address => DeployData) public users;
    mapping(address => uint256)    public autoDeployUntil;      // timestamp
    mapping(address => uint256)    public nonces;               // EIP-712 nonce
    mapping(address => uint256)    public lastRelayedDeployDay; // day number — one relayed deploy per day

    bool public isPaused;

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event Deploy(
        address indexed user,
        address indexed deployed,
        uint256 indexed day,
        uint256 streak,
        uint256 totalDeploys
    );

    event AutoDeployPurchased(
        address indexed user,
        uint256 durationDays,
        uint256 autoDeployUntil
    );

    event NonceIncremented(address indexed user, uint256 newNonce);
    event PriceUpdated(string priceType, uint256 newPrice);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);

    // ---------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "DeployFactory: Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!isPaused, "DeployFactory: paused");
        _;
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    constructor(uint256 _deployPrice, uint256 _autoDeployPricePerDay, address payable _collector, address payable _relayer) {
        owner = msg.sender;
        collector = _collector == address(0) ? payable(msg.sender) : _collector;
        relayer = _relayer;
        deployPrice = _deployPrice;
        autoDeployPricePerDay = _autoDeployPricePerDay;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes(NAME)),
                keccak256(bytes(VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    // ---------------------------------------------------------------
    // Core — Manual Deploy
    // ---------------------------------------------------------------

    /**
     * @notice Deploy a MinimalContract owned by msg.sender. Requires payment of `deployPrice`.
     *         Required funds are forwarded to `collector`, excess is refunded to the payer.
     */
    function deploySelf() external payable whenNotPaused {
        require(msg.value >= deployPrice, "DeployFactory: Insufficient payment");
        _deploy(msg.sender);
        uint256 refund = msg.value - deployPrice;

        if (deployPrice > 0) {
            (bool okCollector, ) = collector.call{value: deployPrice}("");
            require(okCollector, "DeployFactory: Transfer to collector failed");
        }

        // Refund any excess back to the payer.
        if (refund > 0) {
            (bool okRefund, ) = payable(msg.sender).call{value: refund}("");
            require(okRefund, "DeployFactory: Refund to buyer failed");
        }
    }

    // ---------------------------------------------------------------
    // Core — AutoDeploy Purchase
    // ---------------------------------------------------------------

    /**
     * @notice Purchase an AutoDeploy subscription for `durationDays` days.
     *         If an existing subscription is still active, the new duration
     *         extends from the current expiry; otherwise it starts now.
     *         Required funds are forwarded to `collector`, excess is refunded to the payer.
     */
    function purchaseAutoDeploy(uint256 _durationDays) external payable whenNotPaused {
        require(_durationDays > 0, "DeployFactory: Zero duration");
        uint256 requiredAmount = autoDeployPricePerDay * _durationDays;
        require(msg.value >= requiredAmount, "DeployFactory: Insufficient payment");

        uint256 start = autoDeployUntil[msg.sender] >= block.timestamp
            ? autoDeployUntil[msg.sender]
            : block.timestamp;

        uint256 startDay = start / 1 days;
        uint256 firstDay = autoDeployUntil[msg.sender] >= block.timestamp ? startDay + 1 : startDay;
        autoDeployUntil[msg.sender] = (firstDay + _durationDays) * 1 days - 1; // end of last day

        emit AutoDeployPurchased(msg.sender, _durationDays, autoDeployUntil[msg.sender]);

        uint256 refund = msg.value - requiredAmount;

        if (requiredAmount > 0) {
            uint256 relayerShare = requiredAmount / 8;
            uint256 collectorShare = requiredAmount - relayerShare;

            if (relayerShare > 0 && relayer != address(0)) {
                (bool okRelayer, ) = relayer.call{value: relayerShare}("");
                require(okRelayer, "DeployFactory: Transfer to relayer failed");
            } else {
                collectorShare = requiredAmount;
            }

            (bool okCollector, ) = collector.call{value: collectorShare}("");
            require(okCollector, "DeployFactory: Transfer to collector failed");
        }

        if (refund > 0) {
            (bool okRefund, ) = payable(msg.sender).call{value: refund}("");
            require(okRefund, "DeployFactory: Refund to buyer failed");
        }
    }

    // ---------------------------------------------------------------
    // Core — Relayed Deploy (called by backend)
    // ---------------------------------------------------------------

    /**
     * @notice Deploy a MinimalContract on behalf of `user`. Called by the backend relayer.
     *         Requires a valid EIP-712 signature from `user` and an active AutoDeploy subscription.
     * @param _user      The address to record the deploy for (MinimalContract owner).
     * @param _nonce     The nonce used when the user signed the authorization.
     * @param _deadline  The deadline timestamp from the signed message.
     * @param _signature The EIP-712 signature (65 bytes: r + s + v).
     */
    function deployRelayed(
        address _user,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) external whenNotPaused {
        uint256 today = block.timestamp / 86400;
        require(lastRelayedDeployDay[_user] < today, "DeployFactory: Already relayed today");
        require(autoDeployUntil[_user] >= block.timestamp, "DeployFactory: AutoDeploy expired");
        require(block.timestamp <= _deadline, "DeployFactory: Signature deadline passed");
        require(_nonce == nonces[_user], "DeployFactory: Invalid nonce");

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(abi.encode(AUTODEPLOY_TYPEHASH, _user, _nonce, _deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);

        address signer = digest.recover(_signature);
        require(signer == _user, "DeployFactory: Invalid signature");

        lastRelayedDeployDay[_user] = today;
        _deploy(_user);
    }

    /**
     * @notice Deploy for multiple users in one transaction. Skips entries that fail validation
     *         (expired subscription, invalid nonce/signature, already deployed today) instead of reverting.
     * @param _users      Array of addresses to record deploy for.
     * @param _nonces     Array of nonces (one per user).
     * @param _deadlines  Array of deadline timestamps (one per user).
     * @param _signatures Array of EIP-712 signatures (one per user).
     */
    function deployRelayedBatch(
        address[] calldata _users,
        uint256[] calldata _nonces,
        uint256[] calldata _deadlines,
        bytes[] calldata _signatures
    ) external whenNotPaused {
        uint256 n = _users.length;
        require(n == _nonces.length && n == _deadlines.length && n == _signatures.length, "DeployFactory: Array length mismatch");
        require(n > 0 && n <= 50, "DeployFactory: Batch size 1-50");

        uint256 today = block.timestamp / 86400;

        for (uint256 i = 0; i < n; i++) {
            address user = _users[i];
            if (lastRelayedDeployDay[user] >= today) continue;
            if (autoDeployUntil[user] < block.timestamp) continue;
            if (block.timestamp > _deadlines[i]) continue;
            if (_nonces[i] != nonces[user]) continue;

            bytes32 structHash = keccak256(abi.encode(AUTODEPLOY_TYPEHASH, user, _nonces[i], _deadlines[i]));
            bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
            (address signer, ECDSA.RecoverError err, ) = digest.tryRecover(_signatures[i]);
            if (err != ECDSA.RecoverError.NoError || signer != user) continue;

            lastRelayedDeployDay[user] = today;
            _deploy(user);
        }
    }

    // ---------------------------------------------------------------
    // Nonce Management
    // ---------------------------------------------------------------

    /**
     * @notice Increment your nonce to revoke any outstanding AutoDeploy authorization.
     */
    function incrementNonce() external {
        nonces[msg.sender]++;
        emit NonceIncremented(msg.sender, nonces[msg.sender]);
    }

    // ---------------------------------------------------------------
    // View Functions
    // ---------------------------------------------------------------

    /**
     * @notice Returns the current deploy streak for `user`.
     *         Returns 0 if the streak is already broken (missed yesterday).
     */
    function getDeployStreak(address _user) external view returns (uint256) {
        DeployData storage data = users[_user];
        uint256 today = block.timestamp / 86400;

        if (data.lastDeployDay == today || data.lastDeployDay == today - 1) {
            return data.streak;
        }
        return 0;
    }

    /**
     * @notice Returns the total lifetime deploy count for `user`.
     */
    function getDeployCount(address _user) external view returns (uint256) {
        return users[_user].totalDeploys;
    }

    /**
     * @notice Returns true if `user` has already deployed today.
     */
    function hasDeployedToday(address _user) external view returns (bool) {
        return users[_user].lastDeployDay == block.timestamp / 86400;
    }

    /**
     * @notice Returns the EIP-712 domain separator for this contract instance.
     */
    function domainSeparator() external view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }

    // ---------------------------------------------------------------
    // Owner Functions
    // ---------------------------------------------------------------

    function setDeployPrice(uint256 _deployPrice) external onlyOwner {
        deployPrice = _deployPrice;
        emit PriceUpdated("deployPrice", _deployPrice);
    }

    function setAutoDeployPricePerDay(uint256 _autoDeployPricePerDay) external onlyOwner {
        autoDeployPricePerDay = _autoDeployPricePerDay;
        emit PriceUpdated("autoDeployPricePerDay", _autoDeployPricePerDay);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "DeployFactory: Zero address");
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "DeployFactory: Not pending owner");
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function setCollector(address payable _newCollector) external onlyOwner {
        require(_newCollector != address(0), "DeployFactory: Zero address");
        require(collector != _newCollector, "DeployFactory: Same collector");
        collector = _newCollector;
    }

    function setRelayer(address payable _newRelayer) external onlyOwner {
        require(_newRelayer != address(0), "DeployFactory: Zero address");
        require(relayer != _newRelayer, "DeployFactory: Same relayer");
        relayer = _newRelayer;
    }

    /// @notice Pause deploy, AutoDeploy purchase, and relay entrypoints. Owner-only; does not block views, nonce revoke, or withdraw.
    function pause() external onlyOwner {
        require(!isPaused, "DeployFactory: Already paused");
        isPaused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume normal operation after `pause()`.
    function unpause() external onlyOwner {
        require(isPaused, "DeployFactory: Not paused");
        isPaused = false;
        emit Unpaused(msg.sender);
    }

    function withdraw(address payable _to) external onlyOwner {
        require(_to != address(0), "DeployFactory: Invalid address");

        uint256 balance = address(this).balance;
        require(balance > 0, "DeployFactory: No balance");
        (bool success, ) = _to.call{value: balance}("");
        require(success, "DeployFactory: Withdraw failed");
    }

    fallback() external payable {
        revert("DeployFactory: No calls accepted");
    }

    receive() external payable {
        revert("DeployFactory: No funds accepted");
    }

    // ---------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------

    function _deploy(address _user) internal {
        uint256 today = block.timestamp / 86400;
        DeployData storage data = users[_user];

        // Deploy MinimalContract owned by user
        MinimalContract deployed = new MinimalContract(_user);

        if (data.lastDeployDay < today) {
            if (data.lastDeployDay == today - 1) {
                data.streak++;
            } else {
                data.streak = 1;
            }

            data.lastDeployDay = today;
        }

        data.totalDeploys++;

        emit Deploy(_user, address(deployed), today, data.streak, data.totalDeploys);
    }

}
