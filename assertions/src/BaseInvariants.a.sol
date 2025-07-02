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
  address public immutable targetAsset;
  IMockL2Pool public immutable pool;

  constructor(address _pool, address _asset) {
    pool = IMockL2Pool(_pool);
    targetAsset = _asset;
  }
  function triggers() public view override {
    // Register storage trigger for totalSupply (slot 2) of the debt token
    // NOTE: this is currently not a supported trigger cheatcode,
    //so we have to trigger on all calls to functions that affect the debt token supply
    // registerStorageChangeTrigger(this.assertDebtTokenSupply.selector, debtToken, 2);

    // Below approach is inefficient since we have to trigger on all calls to functions that _could_
    // affect the debt token supply, but without being sure that it's the token
    // at the address of the debt token initiated in the constructor.
    registerCallTrigger(this.assertDebtTokenSupply.selector, IMockL2Pool.borrow.selector);
    registerCallTrigger(this.assertDebtTokenSupply.selector, IMockL2Pool.repay.selector);
    registerCallTrigger(this.assertDebtTokenSupply.selector, IMockL2Pool.liquidationCall.selector);
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

    uint256 totalIncrease = 0;
    uint256 totalDecrease = 0;

    // Process borrow operations (increase debt) - only VARIABLE mode affects variable debt token
    for (uint256 i = 0; i < borrowCalls.length; i++) {
      bytes32 args = abi.decode(borrowCalls[i].input, (bytes32));

      // Decode using the same logic as CalldataLogic.decodeBorrowParams
      uint16 assetId;
      uint256 amount;
      uint256 interestRateMode;
      uint16 referralCode;

      assembly {
        assetId := and(args, 0xFFFF)
        amount := and(shr(16, args), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        interestRateMode := and(shr(144, args), 0xFF)
        referralCode := and(shr(152, args), 0xFFFF)
      }

      // Get the asset address from the assetId and check if it matches our target asset
      address asset = pool.getReserveAddressById(assetId);
      if (
        asset == targetAsset && interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)
      ) {
        IERC20 underlying = IERC20(targetAsset);

        // Get user address from the caller
        address user = borrowCalls[i].caller;

        // Get pre and post state
        ph.forkPreState();
        uint256 preBalance = underlying.balanceOf(user);

        ph.forkPostState();
        uint256 postBalance = underlying.balanceOf(user);

        // Calculate actual balance change
        // Borrow always increases the balance of the user
        uint256 actualBalanceChange = postBalance - preBalance;

        // The user should receive exactly `amount` tokens
        require(actualBalanceChange == amount, 'User received incorrect amount on borrow');
        totalIncrease += amount;
      }
    }

    // Process repay operations (decrease debt) - only VARIABLE mode affects variable debt token
    for (uint256 i = 0; i < repayCalls.length; i++) {
      bytes32 args = abi.decode(repayCalls[i].input, (bytes32));

      // Decode using the same logic as CalldataLogic.decodeRepayParams
      uint16 assetId;
      uint256 amount;
      uint256 interestRateMode;

      assembly {
        assetId := and(args, 0xFFFF)
        amount := and(shr(16, args), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        interestRateMode := and(shr(144, args), 0xFF)
      }

      if (amount == type(uint128).max) {
        amount = type(uint256).max;
      }

      address asset = pool.getReserveAddressById(assetId);
      if (
        asset == targetAsset && interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)
      ) {
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

      address asset = pool.getReserveAddressById(debtAssetId);
      if (asset == targetAsset) {
        totalDecrease += debtToCover;
      }
    }

    // Calculate net change in user underlying balances
    uint256 netDebtChange = totalIncrease - totalDecrease;

    // Compare calculated underlying balance changes with actual on-chain debt token supply
    // Get the variable debt token for this asset
    address variableDebtToken = pool.getReserveData(targetAsset).variableDebtTokenAddress;

    // Debug: Log the debt token address to verify we're getting the right one
    require(variableDebtToken != address(0), 'Variable debt token address is zero');

    IERC20 debtToken = IERC20(variableDebtToken);

    // Get pre and post state of debt token total supply
    ph.forkPreState();
    uint256 preDebtSupply = debtToken.totalSupply();

    ph.forkPostState();
    uint256 postDebtSupply = debtToken.totalSupply();

    uint256 actualDebtSupplyChange = postDebtSupply - preDebtSupply;

    // The calculated net debt change should match the actual debt token supply change
    require(
      netDebtChange == actualDebtSupplyChange,
      'Calculated debt change does not match actual debt token supply change'
    );

    // Additional safety check: debt supply should not decrease more than it increases
    require(netDebtChange >= 0, 'Net debt change should be non-negative');
  }
}
