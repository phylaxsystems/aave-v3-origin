// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from '../interfaces/IMockL2Pool.sol';
import {IERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {DataTypes} from '../../../src/contracts/protocol/libraries/types/DataTypes.sol';

/**
 * @title BorrowLogicErrorAssertion
 * @notice Assertions for detecting the specific bug in BorrowLogic.sol
 * @dev This assertion should fail when the 333e6 bug is triggered
 */
contract BorrowLogicErrorAssertion is Assertion {
  address public immutable targetAsset;
  IMockL2Pool public immutable pool;

  constructor(address _pool, address _asset) {
    pool = IMockL2Pool(_pool);
    targetAsset = _asset;
  }
  function triggers() public view override {
    registerCallTrigger(
      this.assertBorrowAmountMatchesUnderlyingBalanceChange.selector,
      IMockL2Pool.borrow.selector
    );
  }

  // Make sure that the borrow amount matches the underlying token balance change
  function assertBorrowAmountMatchesUnderlyingBalanceChange() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);

    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));

      // Get the asset address from the pool and check if it matches our target asset
      address asset = pool.getReserveAddressById(assetId);
      if (asset != targetAsset) continue; // Skip if not our target asset

      IERC20 underlying = IERC20(targetAsset);

      // Get user address from the caller
      address user = callInputs[i].caller;

      // Get pre and post state
      ph.forkPreState();
      uint256 preBalance = underlying.balanceOf(user);

      ph.forkPostState();
      uint256 postBalance = underlying.balanceOf(user);

      // Calculate actual balance change
      // Borrow always increases the balance of the user
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
