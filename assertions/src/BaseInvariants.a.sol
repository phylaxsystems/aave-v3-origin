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
contract BaseInvariants is Assertion {
  IPool public immutable pool;
  IERC20 public immutable asset;

  constructor(address poolAddress, address assetAddress) {
    pool = IPool(poolAddress);
    asset = IERC20(assetAddress);
  }

  function triggers() public view override {
    // Register storage trigger for totalSupply (slot 2) of the debt token
    // NOTE: this is currently not a supported trigger cheatcode,
    //so we have to trigger on all calls to functions that affect the debt token supply
    // registerStorageChangeTrigger(this.assertDebtTokenSupply.selector, debtToken, 2);

    // Below approach is inefficient since we have to trigger on all calls to functions that _could_
    // affect the debt token supply, but without being sure that it's the token
    // at the address of the debt token initiated in the constructor.
    registerCallTrigger(this.assertDebtTokenSupply.selector, pool.borrow.selector);
    registerCallTrigger(this.assertDebtTokenSupply.selector, pool.repay.selector);
    registerCallTrigger(this.assertDebtTokenSupply.selector, pool.liquidationCall.selector);
  }

  /*/////////////////////////////////////////////////////////////////////////////////////////////
        BASE_INVARIANT_A: debtToken totalSupply should be equal to the sum of all user balances (user debt)
        This is verified by ensuring that the sum of individual balance changes matches the total supply change
        for a specific asset
    /////////////////////////////////////////////////////////////////////////////////////////////*/
  function assertDebtTokenSupply() external {
    // Get all operations that affect debt token supply
    PhEvm.CallInputs[] memory borrowCalls = ph.getCallInputs(address(pool), pool.borrow.selector);
    PhEvm.CallInputs[] memory repayCalls = ph.getCallInputs(address(pool), pool.repay.selector);
    PhEvm.CallInputs[] memory liquidationCalls = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );

    // Track changes for the specific asset
    int256 balanceChange;

    // Process borrow operations (increase debt)
    for (uint256 i = 0; i < borrowCalls.length; i++) {
      (address borrowAsset, uint256 amount, , , ) = abi.decode(
        borrowCalls[i].input,
        (address, uint256, uint256, uint16, address)
      );
      if (borrowAsset == asset) {
        balanceChange += int256(amount);
      }
    }

    // Process repay operations (decrease debt)
    for (uint256 i = 0; i < repayCalls.length; i++) {
      (address repayAsset, uint256 amount, , ) = abi.decode(
        repayCalls[i].input,
        (address, uint256, uint256, address)
      );
      if (repayAsset == asset) {
        balanceChange -= int256(amount);
      }
    }

    // Process liquidation operations (decrease debt)
    for (uint256 i = 0; i < liquidationCalls.length; i++) {
      (address collateralAsset, address debtAsset, address user, uint256 debtToCover, ) = abi
        .decode(liquidationCalls[i].input, (address, address, address, uint256, bool));
      if (debtAsset == asset) {
        balanceChange -= int256(debtToCover);
      }
    }

    // Verify the total supply change matches the sum of individual changes
    _verifyDebtTokenSupplyChange(balanceChange);
  }

  /**
   * @notice Verifies that the change in debt token total supply matches the sum of individual balance changes
   * @param expectedChange The expected change in total supply (positive for borrows, negative for repays/liquidations)
   */
  function _verifyDebtTokenSupplyChange(int256 expectedChange) internal {
    // Get debt token address
    (, , address debtToken) = pool.getReserveData(asset);

    // Get pre-state total supply
    ph.forkPreState();
    uint256 preSupply = IERC20(debtToken).totalSupply();

    // Get post-state total supply
    ph.forkPostState();
    uint256 postSupply = IERC20(debtToken).totalSupply();

    // Calculate actual change
    int256 actualChange = int256(postSupply) - int256(preSupply);

    // Verify the changes match
    require(
      actualChange == expectedChange,
      'Debt token supply change does not match individual balance changes'
    );
  }
}
