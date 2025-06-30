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
  IPool public pool;
  IERC20 public asset;

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

    // If no operations affecting this asset, skip the check
    if (borrowCalls.length == 0 && repayCalls.length == 0 && liquidationCalls.length == 0) {
      return;
    }

    uint256 totalIncrease = 0;
    uint256 totalDecrease = 0;

    // Process borrow operations (increase debt) - only VARIABLE mode affects variable debt token
    for (uint256 i = 0; i < borrowCalls.length; i++) {
      (address borrowAsset, uint256 amount, uint256 interestRateMode, , ) = abi.decode(
        borrowCalls[i].input,
        (address, uint256, uint256, uint16, address)
      );
      if (
        borrowAsset == address(asset) &&
        interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)
      ) {
        totalIncrease += amount;
      }
    }

    // // Process repay operations (decrease debt) - only VARIABLE mode affects variable debt token
    // for (uint256 i = 0; i < repayCalls.length; i++) {
    //   (address repayAsset, uint256 amount, uint256 interestRateMode, ) = abi.decode(
    //     repayCalls[i].input,
    //     (address, uint256, uint256, address)
    //   );
    //   if (
    //     repayAsset == address(asset) &&
    //     interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)
    //   ) {
    //     totalDecrease += amount;
    //   }
    // }

    // // Process liquidation operations (decrease debt)
    // for (uint256 i = 0; i < liquidationCalls.length; i++) {
    //   (, address debtAsset, , uint256 debtToCover, ) = abi.decode(
    //     liquidationCalls[i].input,
    //     (address, address, address, uint256, bool)
    //   );
    //   if (debtAsset == address(asset)) {
    //     totalDecrease += debtToCover;
    //   }
    // }

    // If no operations affected this specific asset, skip the check
    if (totalIncrease == 0 && totalDecrease == 0) {
      return;
    }

    // Get variable debt token address
    DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(address(asset));
    address variableDebtTokenAddress = reserveData.variableDebtTokenAddress;
    IERC20 variableDebtToken = IERC20(variableDebtTokenAddress);

    // Get pre-state total supply
    ph.forkPreState();
    uint256 preDebt = variableDebtToken.totalSupply();

    // Get post-state total supply
    ph.forkPostState();
    uint256 postDebt = variableDebtToken.totalSupply();

    // Calculate expected change: borrows increase, repays/liquidations decrease
    int256 expectedChange = int256(totalIncrease) - int256(totalDecrease);

    // Calculate actual change
    int256 actualChange = int256(postDebt) - int256(preDebt);

    // The invariant is that the debt token total supply should increase by the amount of the borrow
    // and decrease by the amount of the repay or liquidation.
    // If the invariant is violated, it means that the debt token total supply is not correctly updated.
    require(
      actualChange == expectedChange,
      'Debt token supply change does not match individual balance changes'
    );
  }
}
