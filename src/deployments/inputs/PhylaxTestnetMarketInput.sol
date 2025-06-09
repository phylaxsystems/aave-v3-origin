// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import './MarketInput.sol';

contract PhylaxTestnetMarketInput is MarketInput {
  function _getMarketInput(
    address deployer
  )
    internal
    pure
    override
    returns (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory deployedContracts
    )
  {
    roles.marketOwner = deployer;
    roles.emergencyAdmin = deployer;
    roles.poolAdmin = deployer;

    config.marketId = 'Aave V3 PhylaxTestnet Market';
    config.providerId = 808080;
    config.oracleDecimals = 8;
    config.flashLoanPremiumTotal = 0.0005e4;
    config.flashLoanPremiumToProtocol = 0.0004e4;
    config.networkBaseTokenPriceInUsdProxyAggregator = 0x659CD5653Eb1ef3167c3C423CDaFa5eDE909313a; // mock aggregator
    config
      .marketReferenceCurrencyPriceInUsdProxyAggregator = 0x659CD5653Eb1ef3167c3C423CDaFa5eDE909313a; // mock aggregator
    config.wrappedNativeToken = 0xE57a499886766d5e3CD9847390E4D11d75a8e2ED; // WETH9 address

    return (roles, config, flags, deployedContracts);
  }
}
