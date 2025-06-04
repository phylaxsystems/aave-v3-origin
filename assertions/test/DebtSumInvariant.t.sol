// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title BorrowingInvariantAssertions Tests
 * @notice This test file uses the real Aave V3 protocol to verify that our assertions
 *         correctly pass when the protocol behaves as expected. It ensures that our
 *         assertions don't revert when they shouldn't, validating that our invariant
 *         checks are not overly restrictive.
 *
 *         For example, it verifies that the liability decrease assertion passes when
 *         a user successfully repays their debt, as the real protocol correctly
 *         decreases the user's debt.
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {BaseInvariants} from '../src/BaseInvariants.a.sol';
import {IMockPool} from '../src/IMockPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';

contract TestBorrowingInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockPool public pool;
  BaseInvariants public assertions;
  address public user;
  address public asset;
  IERC20 public underlying;
  IERC20 public variableDebtToken;
  string public constant ASSERTION_LABEL = 'DebtSumInvariant';

  function setUp() public {
    // Initialize test environment with real contracts
    initTestEnvironment();

    // Set up user and get pool reference
    user = alice;
    pool = IMockPool(report.poolProxy);
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Deploy assertions contract
    assertions = new BaseInvariants(address(pool), address(underlying));

    // Get variable debt token
    (, , address variableDebtUSDX) = contracts.protocolDataProvider.getReserveTokensAddresses(
      asset
    );
    variableDebtToken = IERC20(variableDebtUSDX);

    // Set up fresh user with collateral
    deal(asset, user, 2000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);
    pool.supply(asset, 1000e6, user, 0); // Supply collateral first
    vm.stopPrank();
  }

  function testAssertionBorrowBug() public {
    // For testing purposes, we have introduced a bug in the borrow function
    // When trying to borrow exactly 333e6, the user will receive double the amount
    // and the total debt will not be correctly updated

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BaseInvariants).creationCode,
      abi.encode(address(pool), address(underlying))
    );

    vm.prank(user);
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
  }

  function testAssertionBorrowNormal() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BaseInvariants).creationCode,
      abi.encode(address(pool), address(underlying))
    );

    vm.prank(user);
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
  }

  function testBorrowInvariantManual() public {
    vm.startPrank(user);

    // Get aToken address for the asset
    (address aTokenAddr, , ) = contracts.protocolDataProvider.getReserveTokensAddresses(asset);
    IERC20 aToken = IERC20(aTokenAddr);

    // --- Normal borrow: should work as expected ---
    uint256 beforeDebtTotal = variableDebtToken.totalSupply();
    uint256 beforeATokenTotal = aToken.totalSupply();
    emit log_named_uint('aToken totalSupply before normal borrow', beforeATokenTotal);
    emit log_named_uint('DebtToken totalSupply before normal borrow', beforeDebtTotal);
    pool.borrow(asset, 100e6, uint256(DataTypes.InterestRateMode.VARIABLE), 0, user);
    uint256 afterDebtTotal = variableDebtToken.totalSupply();
    uint256 afterATokenTotal = aToken.totalSupply();
    emit log_named_uint('aToken totalSupply after normal borrow', afterATokenTotal);
    emit log_named_uint('DebtToken totalSupply after normal borrow', afterDebtTotal);
    emit log_named_uint('aToken delta (normal)', afterATokenTotal - beforeATokenTotal);
    emit log_named_uint('DebtToken delta (normal)', afterDebtTotal - beforeDebtTotal);
    assertEq(
      afterATokenTotal - beforeATokenTotal,
      0,
      'aToken totalSupply should not change on borrow'
    );
    assertEq(
      afterDebtTotal - beforeDebtTotal,
      100e6,
      'DebtToken totalSupply should increase by borrowed amount'
    );
    vm.stopPrank();
  }
}
