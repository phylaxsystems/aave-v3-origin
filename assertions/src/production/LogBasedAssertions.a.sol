// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from '../interfaces/IMockL2Pool.sol';
import {DataTypes} from '../../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

/// @title LogBasedAssertions
/// @notice Implements log-based assertions for Aave V3 L2Pool
/// @dev These assertions use event logs for validation, providing resilience against proxy/delegatecall patterns
contract LogBasedAssertions is Assertion {
  function triggers() public view override {
    // Register triggers for log-based validation
    registerCallTrigger(
      this.assertBorrowBalanceChangesFromLogs.selector,
      IMockL2Pool.borrow.selector
    );
  }

  // BORROWING_HSPOST_I: After a successful borrow the actor asset balance should increase by the amount borrowed
  // This version uses getLogs to access the Borrow event data instead of call inputs
  // It's more complex but works even if the function is called through a proxy or delegatecall
  // since it relies on the event being emitted rather than the direct function call
  // Gas cost of this assertion for a single borrow transaction: 42739
  function assertBorrowBalanceChangesFromLogs() external {
    PhEvm.Log[] memory logs = ph.getLogs();
    for (uint256 i = 0; i < logs.length; i++) {
      if (
        logs[i].topics[0] ==
        keccak256('Borrow(address,address,address,uint256,uint8,uint256,uint16)')
      ) {
        // Get indexed fields from topics
        address reserve = address(uint160(uint256(logs[i].topics[1])));

        // Get non-indexed fields from data
        (
          address user,
          uint256 amount,
          ,
          
        ) = abi.decode(logs[i].data, (address, uint256, DataTypes.InterestRateMode, uint256));

        // Get underlying token
        IERC20 underlying = IERC20(reserve);

        // Get balances before
        ph.forkPreState();
        uint256 preBalance = underlying.balanceOf(user);

        // Get balances after
        ph.forkPostState();
        uint256 postBalance = underlying.balanceOf(user);

        // Check balance increased by amount
        require(postBalance - preBalance == amount, 'Balance did not increase by borrow amount');
      }
    }
  }
}
