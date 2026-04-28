// gmPrice, autoGMPricePerDay, collector, relayer
// 0.4 SOMI,  0.5 SOMI
// 400000000000000000, 500000000000000000, 0xcc433247d87bf92b4e36cf923f02d42e1e1466fb, 0xd42940c98F5B8E31B18D5c2F5d8C349d56b96BE1
// 0.00004, 0.00005
// 40000000000000, 50000000000000, 0xcc433247d87bf92b4e36cf923f02d42e1e1466fb, 0xd42940c98F5B8E31B18D5c2F5d8C349d56b96BE1

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title GMContract
 * @notice On-chain daily GM tracker with AutoGM relay support via EIP-712.
 *         Tracks per-user streaks, total GM count, and supports auto GM subscriptions.
 */
contract GMContract {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ---------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------

    struct UserData {
        uint256 lastGMDay; // day number (block.timestamp / 86400)
        uint256 streak;    // current consecutive-day streak
        uint256 totalGMs;  // lifetime GM count
    }

    // ---------------------------------------------------------------
    // Constants — EIP-712
    // ---------------------------------------------------------------

    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 public constant AUTOGM_TYPEHASH =
        keccak256("AutoGMAuth(address user,uint256 nonce,uint256 deadline)");

    string public constant NAME    = "AutoGM";
    string public constant VERSION = "1";

    // ---------------------------------------------------------------
    // State
    // ---------------------------------------------------------------

    address public owner;
    address public pendingOwner;
    address payable public collector;
    address payable public relayer;

    bytes32 public immutable DOMAIN_SEPARATOR;

    uint256 public gmPrice;           // wei required for gmSelf()
    uint256 public autoGMPricePerDay; // wei per day for AutoGM subscription

    mapping(address => UserData)  public users;
    mapping(address => uint256)   public autoGMUntil;      // timestamp
    mapping(address => uint256)   public nonces;           // EIP-712 nonce
    mapping(address => uint256)   public lastRelayedGMDay; // day number — one relayed GM per day

    bool public isPaused;

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event GM(
        address indexed user,
        uint256 indexed day,
        uint256 streak,
        uint256 totalGMs
    );

    event AutoGMPurchased(
        address indexed user,
        uint256 durationDays,
        uint256 autoGMUntil
    );

    event NonceIncremented(address indexed user, uint256 newNonce);
    event GMPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event AutoGMPricePerDayUpdated(uint256 oldPrice, uint256 newPrice);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);

    // ---------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "GMContract: not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!isPaused, "GMContract: Paused");
        _;
    }

    // ---------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------

    constructor(uint256 _gmPrice, uint256 _autoGMPricePerDay, address payable _collector, address payable _relayer) {
        owner             = msg.sender;
        collector         = _collector == address(0) ? payable(msg.sender) : _collector;
        relayer           = _relayer;
        gmPrice           = _gmPrice;
        autoGMPricePerDay = _autoGMPricePerDay;
        DOMAIN_SEPARATOR  = keccak256(
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
    // Core — Manual GM
    // ---------------------------------------------------------------

    /// @notice Send a daily GM. Requires payment of `gmPrice`. Required funds are forwarded to `collector`, excess is refunded to the payer.
    function gmSelf() external payable whenNotPaused {
        require(msg.value >= gmPrice, "GMContract: Insufficient payment");
        _recordGM(msg.sender);
        uint256 refund = msg.value - gmPrice;

        if (gmPrice > 0) {
            (bool okCollector, ) = collector.call{value: gmPrice}("");
            require(okCollector, "GMContract: Transfer to collector failed");
        }

        // Refund any excess back to the payer.
        if (refund > 0) {
            (bool okRefund, ) = payable(msg.sender).call{value: refund}("");
            require(okRefund, "GMContract: Refund to buyer failed");
        }
    }

    // ---------------------------------------------------------------
    // Core — AutoGM Purchase
    // ---------------------------------------------------------------

    /**
     * @notice Purchase an AutoGM subscription for `durationDays` days.
     *         If an existing subscription is still active, the new duration
     *         extends from the current expiry; otherwise it starts now.
     *         Required funds are forwarded to `collector`, excess is refunded to the payer.
     */
    function purchaseAutoGM(uint256 _durationDays) external payable whenNotPaused {
        require(_durationDays > 0, "GMContract: Zero duration");
        uint256 requiredAmount = autoGMPricePerDay * _durationDays;
        require(msg.value >= requiredAmount, "GMContract: Insufficient payment");

        uint256 start = autoGMUntil[msg.sender] > block.timestamp
            ? autoGMUntil[msg.sender]
            : block.timestamp;

        uint256 startDay = start / 1 days;
        uint256 firstDay = autoGMUntil[msg.sender] > block.timestamp ? startDay + 1 : startDay;
        autoGMUntil[msg.sender] = (firstDay + _durationDays) * 1 days - 1; // end of last day

        emit AutoGMPurchased(msg.sender, _durationDays, autoGMUntil[msg.sender]);

        uint256 refund = msg.value - requiredAmount;

        if (requiredAmount > 0) {
            uint256 relayerShare = requiredAmount / 8;
            uint256 collectorShare = requiredAmount - relayerShare;

            if (relayerShare > 0 && relayer != address(0)) {
                (bool okRelayer, ) = relayer.call{value: relayerShare}("");
                require(okRelayer, "GMContract: Transfer to relayer failed");
            } else {
                collectorShare = requiredAmount;
            }

            (bool okCollector, ) = collector.call{value: collectorShare}("");
            require(okCollector, "GMContract: Transfer to collector failed");
        }

        if (refund > 0) {
            (bool okRefund, ) = payable(msg.sender).call{value: refund}("");
            require(okRefund, "GMContract: Refund to buyer failed");
        }
    }

    // ---------------------------------------------------------------
    // Core — Relayed GM (called by backend)
    // ---------------------------------------------------------------

    /**
     * @notice Relay a GM on behalf of `user`. Called by the backend relayer.
     *         Requires a valid EIP-712 signature from `user` and an active AutoGM subscription.
     * @param _user      The address to record the GM for.
     * @param _nonce     The nonce used when the user signed the authorization.
     * @param _deadline  The deadline timestamp from the signed message.
     * @param _signature The EIP-712 signature (65 bytes: r + s + v).
     */
    function gmRelayed(
        address _user,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) external whenNotPaused {
        uint256 today = block.timestamp / 86400;
        require(lastRelayedGMDay[_user] < today, "GMContract: Already relayed today");
        require(autoGMUntil[_user] >= block.timestamp, "GMContract: AutoGM expired");
        require(block.timestamp <= _deadline, "GMContract: Signature deadline passed");
        require(_nonce == nonces[_user], "GMContract: Invalid nonce");

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(abi.encode(AUTOGM_TYPEHASH, _user, _nonce, _deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);

        address signer = digest.recover(_signature);
        require(signer == _user, "GMContract: Invalid signature");

        lastRelayedGMDay[_user] = today;
        _recordGM(_user);
    }

    /**
     * @notice Relay GMs for multiple users in one transaction. Skips entries that fail validation
     *         (expired subscription, invalid nonce/signature, already GM today) instead of reverting.
     * @param _users      Array of addresses to record GM for.
     * @param _nonces     Array of nonces (one per user).
     * @param _deadlines  Array of deadline timestamps (one per user).
     * @param _signatures Array of EIP-712 signatures (one per user).
     */
    function gmRelayedBatch(
        address[] calldata _users,
        uint256[] calldata _nonces,
        uint256[] calldata _deadlines,
        bytes[] calldata _signatures
    ) external whenNotPaused {
        uint256 n = _users.length;
        require(n == _nonces.length && n == _deadlines.length && n == _signatures.length, "GMContract: Array length mismatch");
        require(n > 0 && n <= 50, "GMContract: Batch size 1-50");

        uint256 today = block.timestamp / 86400;

        for (uint256 i = 0; i < n; i++) {
            address user = _users[i];
            if (lastRelayedGMDay[user] >= today) continue;
            if (autoGMUntil[user] < block.timestamp) continue;
            if (block.timestamp > _deadlines[i]) continue;
            if (_nonces[i] != nonces[user]) continue;

            bytes32 structHash = keccak256(abi.encode(AUTOGM_TYPEHASH, user, _nonces[i], _deadlines[i]));
            bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
            (address signer, ECDSA.RecoverError err, ) = digest.tryRecover(_signatures[i]);
            if (err != ECDSA.RecoverError.NoError || signer != user) continue;

            lastRelayedGMDay[user] = today;
            _recordGM(user);
        }
    }

    // ---------------------------------------------------------------
    // Nonce Management
    // ---------------------------------------------------------------

    /// @notice Increment your nonce to revoke any outstanding AutoGM authorization.
    function incrementNonce() external {
        nonces[msg.sender]++;
        emit NonceIncremented(msg.sender, nonces[msg.sender]);
    }

    // ---------------------------------------------------------------
    // View Functions
    // ---------------------------------------------------------------

    /**
     * @notice Returns the current GM streak for `user`.
     *         Returns 0 if the streak is already broken (missed yesterday).
     */
    function getGMStreak(address _user) external view returns (uint256) {
        UserData storage data = users[_user];
        uint256 today = block.timestamp / 86400;

        if (data.lastGMDay == today || data.lastGMDay == today - 1)
            return data.streak;

        return 0;
    }

    /// @notice Returns the total lifetime GM count for `user`.
    function getGMCount(address _user) external view returns (uint256) {
        return users[_user].totalGMs;
    }

    /// @notice Returns true if `user` has already sent a GM today.
    function hasGMToday(address _user) external view returns (bool) {
        return users[_user].lastGMDay == block.timestamp / 86400;
    }

    /// @notice Returns the EIP-712 domain separator for this contract instance.
    function domainSeparator() external view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }

    // ---------------------------------------------------------------
    // Owner Functions
    // ---------------------------------------------------------------

    function setGMPrice(uint256 _newGMPrice) external onlyOwner {
        emit GMPriceUpdated(gmPrice, _newGMPrice);
        gmPrice = _newGMPrice;
    }

    function setAutoGMPricePerDay(uint256 _newAutoGMPricePerDay) external onlyOwner {
        emit AutoGMPricePerDayUpdated(autoGMPricePerDay, _newAutoGMPricePerDay);
        autoGMPricePerDay = _newAutoGMPricePerDay;
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "GMContract: Zero address");
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "GMContract: Not pending owner");
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function setCollector(address payable _newCollector) external onlyOwner {
        require(_newCollector != address(0), "GMContract: Zero address");
        require(collector != _newCollector, "GMContract: Same collector");
        collector = _newCollector;
    }

    function setRelayer(address payable _newRelayer) external onlyOwner {
        require(_newRelayer != address(0), "GMContract: Zero address");
        require(relayer != _newRelayer, "GMContract: Same relayer");
        relayer = _newRelayer;
    }

    /// @notice Pause GM, AutoGM purchase, and relay entrypoints. Owner-only; does not block views, nonce revoke, or withdraw.
    function pause() external onlyOwner {
        require(!isPaused, "GMContract: Already paused");
        isPaused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume normal operation after `pause()`.
    function unpause() external onlyOwner {
        require(isPaused, "GMContract: Not paused");
        isPaused = false;
        emit Unpaused(msg.sender);
    }

    function withdraw(address payable _to) external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "GMContract: No balance");
        (bool success, ) = _to.call{value: balance}("");
        require(success, "GMContract: Withdraw failed");
    }

    fallback() external payable {
        revert("GMContract: No calls accepted");
    }

    receive() external payable {
        revert("GMContract: No funds accepted");
    }

    // ---------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------

    function _recordGM(address _user) internal {
        uint256 today = block.timestamp / 86400;
        UserData storage data = users[_user];

        if (data.lastGMDay < today) {
            if (data.lastGMDay == today - 1)
                data.streak++;
            else
                data.streak = 1;

            data.lastGMDay = today;
        }

        data.totalGMs++;

        emit GM(_user, today, data.streak, data.totalGMs);
    }

}
