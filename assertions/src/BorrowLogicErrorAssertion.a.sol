// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IPool} from '../../src/contracts/interfaces/IPool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';

/**
 * @title BaseInvariants
 * @notice Assertions for basic protocol invariants related to token balances and borrowing states for a specific asset
 */
contract BorrowLogicErrorAssertion is Assertion {
  IPool public pool;

  constructor(address poolAddress) {
    pool = IPool(poolAddress);
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
      (address asset, uint256 amount, , , ) = abi.decode(
        callInputs[i].input,
        (address, uint256, uint256, uint16, address)
      );

      // Get underlying token
      IERC20 underlying = IERC20(asset);

      // Get balances before
      ph.forkPreState();
      uint256 preBalance = underlying.balanceOf(callInputs[i].caller);

      // Get balances after
      ph.forkPostState();
      uint256 postBalance = underlying.balanceOf(callInputs[i].caller);

      // Check balance increased by amount
      require(postBalance - preBalance == amount, 'Balance did not increase by borrow amount');
    }
  }
}
