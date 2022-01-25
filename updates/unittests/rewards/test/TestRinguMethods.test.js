const { expect } = require("chai");

describe("TestRinguMethods", () => {
  it("should return the node reward for 1 day", async () => {
    const TestRinguMethods = await ethers.getContractFactory("TestRinguMethods");
    const testRinguMethods = await TestRinguMethods.deploy("Test Ringu Methods");
    await testRinguMethods.deployed();
    expect(await testRinguMethods.getRewardForOneNodeWallet()).to.equal("50006249999998560");
  });
});
