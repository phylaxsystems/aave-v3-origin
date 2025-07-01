// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from './IMockL2Pool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';

/**
 * @title BaseInvariants
 * @notice Assertions for basic protocol invariants related to token balances and borrowing states for a specific asset
 */
contract BorrowLogicErrorAssertion is Assertion {
  IMockL2Pool public pool;

  constructor(address poolAddress) {
    pool = IMockL2Pool(poolAddress);
  }

  function triggers() public view override {
    registerCallTrigger(
      this.assertBorrowAmountMatchesUnderlyingBalanceChange.selector,
      pool.borrow.selector
    );
  }

  // Make sure that the borrow amount matches the underlying token balance change
  function assertBorrowAmountMatchesUnderlyingBalanceChange() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));

      // Get the asset address from the pool
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      IERC20 underlying = IERC20(asset);

      // Get user address from the caller
      address user = callInputs[i].caller;

      // Get pre and post state
      ph.forkPreState();
      uint256 preBalance = underlying.balanceOf(user);

      ph.forkPostState();
      uint256 postBalance = underlying.balanceOf(user);

      // Calculate actual balance change
      uint256 actualBalanceChange = postBalance - preBalance;

      // The user should receive exactly `amount` tokens
      // If the 333e6 bug is present, user will receive double the amount
      require(
        actualBalanceChange == amount,
        'User received incorrect amount on borrow - possible 333e6 bug'
      );
    }
  }
}
