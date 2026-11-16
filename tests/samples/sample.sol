// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* A counter. */
contract Counter {
    uint256 public count;
    event Increased(address indexed by, uint256 value);

    function increase() external {
        count += 1;
        emit Increased(msg.sender, count);
    }
}
