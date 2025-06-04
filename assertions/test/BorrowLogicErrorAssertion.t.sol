// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {BorrowLogicErrorAssertion} from '../src/BorrowLogicErrorAssertion.a.sol';
import {IMockPool} from '../src/IMockPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';

// This test is used to test the borrow logic error assertion.
// There's a bug in the borrow function that allows the user to borrow more than the underlying token balance.

contract TestBorrowingInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockPool public pool;
  BorrowLogicErrorAssertion public assertions;
  address public user;
  address public asset;
  IERC20 public underlying;
  IERC20 public variableDebtToken;
  string public constant ASSERTION_LABEL = 'BorrowLogicErrorAssertion';

  function setUp() public {
    // Initialize test environment with real contracts
    initTestEnvironment();

    // Set up user and get pool reference
    user = alice;
    pool = IMockPool(report.poolProxy);
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Deploy assertions contract
    assertions = new BorrowLogicErrorAssertion(address(pool));

    // Get variable debt token
    (, , address variableDebtUSDX) = contracts.protocolDataProvider.getReserveTokensAddresses(
      asset
    );
    variableDebtToken = IERC20(variableDebtUSDX);
  }

  function testAssertionBorrowBug() public {
    // For testing purposes, we have introduced a bug in the borrow function
    // When trying to borrow exactly 333e6, the user will receive double the amount
    // and the total debt will not be correctly updated

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowLogicErrorAssertion).creationCode,
      abi.encode(address(pool))
    );

    // Set up fresh user with collateral
    deal(asset, user, 2000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);
    pool.supply(asset, 1000e6, user, 0); // Supply collateral first

    vm.expectRevert('Assertions Reverted');
    // This should fail assertions because the user will receive double tokens
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(
        pool.borrow.selector,
        asset,
        333e6, // borrow the evil amount
        uint256(DataTypes.InterestRateMode.VARIABLE),
        0,
        user
      )
    );
    vm.stopPrank();
  }

  function testAssertionBorrowNormal() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowLogicErrorAssertion).creationCode,
      abi.encode(address(pool))
    );

    // Set up fresh user with collateral
    deal(asset, user, 2000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);
    pool.supply(asset, 1000e6, user, 0); // Supply collateral first

    // This should NOT fail assertions because the borrow amount is not the magic number
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(
        pool.borrow.selector,
        asset,
        100e6, // borrow a normal amount
        uint256(DataTypes.InterestRateMode.VARIABLE),
        0,
        user
      )
    );
    vm.stopPrank();
  }
}
