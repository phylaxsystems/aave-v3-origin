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
contract BaseInvariants is Assertion {
  IMockL2Pool public pool;
  IERC20 public asset;

  constructor(address poolAddress, address assetAddress) {
    pool = IMockL2Pool(poolAddress);
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
      bytes32 args = abi.decode(borrowCalls[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      uint256 interestRateMode = uint256(uint8(uint256(args) >> 144));

      // Get the asset address from the assetId by checking reserve data
      // Note: This is a simplified approach - in practice you'd need to maintain a mapping
      // For now, we'll assume the asset matches if the assetId is non-zero
      if (assetId > 0 && interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)) {
        totalIncrease += amount;
      }
    }

    // Process repay operations (decrease debt) - only VARIABLE mode affects variable debt token
    for (uint256 i = 0; i < repayCalls.length; i++) {
      bytes32 args = abi.decode(repayCalls[i].input, (bytes32));
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      uint256 interestRateMode = uint256(uint8(uint256(args) >> 144));

      if (assetId > 0 && interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)) {
        totalDecrease += amount;
      }
    }

    // Process liquidation operations (decrease debt)
    for (uint256 i = 0; i < liquidationCalls.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, bytes32 args2) = abi.decode(liquidationCalls[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      uint16 debtAssetId = uint16(uint256(args1) >> 16);
      uint256 debtToCover = uint256(uint128(uint256(args2)));

      if (debtAssetId > 0) {
        totalDecrease += debtToCover;
      }
    }

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
