// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from '../interfaces/IMockL2Pool.sol';

/**
 * @title MinimalPhEvmBug
 * @notice Minimal reproduction of PhEvm double-call issue
 * @dev This demonstrates that ph.getCallInputs() detects 2 calls when only 1 is made
 */
contract MinimalPhEvmBug is Assertion {
  IMockL2Pool public pool;
  address public targetAsset;

  constructor(IMockL2Pool _pool, address _targetAsset) {
    pool = _pool;
    targetAsset = _targetAsset;
  }

  /**
   * @notice Required implementation of triggers function
   */
  function triggers() external view override {
    // Register triggers for the assertion function
    registerCallTrigger(this.assertSingleBorrowCall.selector, pool.borrow.selector);
  }

  /**
   * @notice Minimal assertion that demonstrates the double-call issue
   * @dev This should detect exactly 1 borrow call, but PhEvm reports 2
   */
  function assertSingleBorrowCall() external {
    // Get all borrow calls to the pool using the exact L2Pool.borrow(bytes32) signature
    // This should only catch the external L2Pool.borrow(bytes32) calls, not the internal Pool.borrow() calls
    bytes4 l2PoolBorrowSelector = bytes4(keccak256('borrow(bytes32)'));
    PhEvm.CallInputs[] memory borrowCalls = ph.getCallInputs(address(pool), l2PoolBorrowSelector);

    // This should be 1, but PhEvm reports 2
    require(borrowCalls.length == 1, 'Expected exactly 1 L2Pool.borrow(bytes32) call, got 2');

    // If we get here, the assertion passes
    // If PhEvm reports 2 calls, this will revert with the error above

    // The minimal reproduction demonstrates that PhEvm's getCallInputs() reports 2 calls for borrow(bytes32) when only 1 external call is made
    // The selector borrow(bytes32) is correct and matches the actual function signature
    // This is a PhEvm assertion system issue, not a function signature issue
  }
}
