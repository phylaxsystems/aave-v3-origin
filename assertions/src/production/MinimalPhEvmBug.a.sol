// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from '../interfaces/IMockL2Pool.sol';
import {IERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {DataTypes} from '../../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from '../../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {WadRayMath} from '../../../src/contracts/protocol/libraries/math/WadRayMath.sol';

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
    registerCallTrigger(this.assertDebtTokenSupplyDebug.selector, pool.borrow.selector);
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

  function assertDebtTokenSupplyDebug() external {
    bytes4 l2PoolBorrowSelector = bytes4(keccak256('borrow(bytes32)'));
    PhEvm.CallInputs[] memory borrowCalls = ph.getCallInputs(address(pool), l2PoolBorrowSelector);

    uint256 totalIncrease = 0;

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

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);

      if (
        asset == targetAsset && interestRateMode == uint256(DataTypes.InterestRateMode.VARIABLE)
      ) {
        totalIncrease += amount;
      }
    }

    address variableDebtToken = pool.getReserveData(targetAsset).variableDebtTokenAddress;

    IERC20 debtToken = IERC20(variableDebtToken);

    // Get pre and post state of debt token total supply
    ph.forkPreState();
    uint256 preDebtSupply = debtToken.totalSupply();

    ph.forkPostState();
    uint256 postDebtSupply = debtToken.totalSupply();

    uint256 actualDebtSupplyChange = postDebtSupply - preDebtSupply;

    require(totalIncrease == 2000e6, 'Total increase does not match expected value');
    require(
      actualDebtSupplyChange == 1000e6,
      'Actual debt supply change does not match expected value'
    );

    // The calculated net debt change should match the actual debt token supply change
    require(
      totalIncrease == actualDebtSupplyChange,
      'Calculated debt change does not match actual debt token supply change'
    );
  }
}
