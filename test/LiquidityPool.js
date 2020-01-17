const {
    BN,
    ether,
    expectRevert,
    time,
    balance,
} = require('openzeppelin-test-helpers');
const { expect } = require('chai');

const LiquidityPool = artifacts.require('LiquidityPool');

contract('liquidity pool test', async () => {
  it('checking pool parameters', async () => {
    this.liquiditypool = await LiquidityPool.new();
    expect(await this.liquiditypool.calcCollateralValue.call('0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF')).to.be.bignumber.equal(ether('0'));
  });
});
