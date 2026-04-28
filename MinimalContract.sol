// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MinimalContract
 * @notice Minimal contract deployed by DeployFactory.
 *         Stores the owner address and deployment timestamp.
 *         Supports ping() for minimal on-chain activity and visibility in explorers.
 */
contract MinimalContract {
    address public immutable owner;
    uint256 public immutable deployedAt;

    uint256 public pingCount;
    uint256 public lastPingAt;

    event Ping(address indexed caller, uint256 indexed count, uint256 timestamp);

    modifier onlyOwner() {
        require(msg.sender == owner, "Contract: Not owner");
        _;
    }

    constructor(address _owner) {
        owner = _owner;
        deployedAt = block.timestamp;
    }

    /// @notice Minimal interaction: anyone can ping to mark the contract as active. Emits event and updates counters.
    function ping() external {
        pingCount += 1;
        lastPingAt = block.timestamp;
        emit Ping(msg.sender, pingCount, lastPingAt);
    }

    fallback() external payable {
        revert("MinimalContract: No calls accepted");
    }

    receive() external payable {
        revert("MinimalContract: No funds accepted");
    }

    function rescueFunds(address payable _to) external onlyOwner {
        require(_to != address(0), "MinimalContract: Invalid address");

        uint256 balance = address(this).balance;
        require(balance > 0, "MinimalContract: No balance");

        (bool success, ) = _to.call{value: balance}("");
        require(success, "MinimalContract: Withdraw failed");
    }
}
