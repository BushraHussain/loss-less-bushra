/* eslint-disable max-len */
/* eslint-disable no-undef */
/* eslint-disable no-unused-vars */
/* eslint-disable prefer-destructuring */
const { time, constants } = require('@openzeppelin/test-helpers');
const { expect } = require('chai');
const path = require('path');
const { setupAddresses, setupEnvironment, setupToken } = require('../utils');

let adr;
let env;
let TestAddress;
let owner;
let addr1;
let addr2;
let addrs;

const scriptName = path.basename(__filename, '.js');

describe(scriptName, () => {
  beforeEach(async () => {


    adr = await setupAddresses();
    env = await setupEnvironment(adr.lssAdmin,
      adr.lssRecoveryAdmin,
      adr.lssPauseAdmin,
      adr.lssInitialHolder,
      adr.lssBackupAdmin);
    lerc20Token = await setupToken(2000000,
      'Random Token',
      'RAND',
      adr.lerc20InitialHolder,
      adr.lerc20Admin.address,
      adr.lerc20BackupAdmin.address,
      Number(time.duration.days(1)),
      env.lssController.address);
    reportedToken = await setupToken(2000000,
      'Reported Token',
      'REPORT',
      adr.lerc20InitialHolder,
      adr.regularUser5.address,
      adr.lerc20BackupAdmin.address,
      Number(time.duration.days(1)),
      env.lssController.address);

    await env.lssController.connect(adr.lssAdmin).setWhitelist([env.lssReporting.address], true);
    await env.lssController.connect(adr.lssAdmin).setDexList([adr.dexAddress.address], true);

    await env.lssGovernance.connect(adr.lssAdmin).addCommitteeMembers([
      adr.member1.address,
      adr.member2.address,
      adr.member3.address,
      adr.member4.address]);

    await env.lssToken.connect(adr.lssInitialHolder)
      .transfer(adr.reporter1.address, env.stakingAmount * 3);

    //**************************** DEPLOY TEST TOKEN ************/    

    let _testAddress = await ethers.getContractFactory("TestIERC");
    [owner, addr1, addr2, ...addrs] = await ethers.getSigners();
    TestAddress = await _testAddress.deploy(10000, "Lexus","LX",owner.address,owner.address,Number(time.duration.days(1)),adr.lssAdmin.address);
    //console.log("Deployed Test token address : " , TestAddress.address);  


    //**************************** TOKEN TRANSFER TO TEST ************/  
    await lerc20Token.connect(adr.lerc20InitialHolder).transfer(TestAddress.address, 1000); 
    //***************************************************/

    await lerc20Token.connect(adr.lerc20InitialHolder).transfer(reportedToken.address, 1000);

    await env.lssToken.connect(adr.reporter1).approve(env.lssReporting.address, env.stakingAmount * 3);

    await ethers.provider.send('evm_increaseTime', [
      Number(time.duration.minutes(5)),
    ]);

    //**************************** REPORT TEST ************/ 
    await env.lssReporting.connect(adr.reporter1)
      .report(lerc20Token.address, TestAddress.address,);
    //***************************************************/
    await env.lssReporting.connect(adr.reporter1)
      .report(lerc20Token.address, reportedToken.address);
  });

  describe('when everyone votes negatively (smart contract address test)', () => {
    beforeEach(async () => {
      await env.lssGovernance.connect(adr.lssAdmin).losslessVote(1, false);
      await env.lssGovernance.connect(adr.lerc20Admin).tokenOwnersVote(1, false);
      await env.lssGovernance.connect(adr.member1).committeeMemberVote(1, false);
      await env.lssGovernance.connect(adr.member2).committeeMemberVote(1, false);
      await env.lssGovernance.connect(adr.member3).committeeMemberVote(1, false);
      await env.lssGovernance.connect(adr.member4).committeeMemberVote(1, false);
    });

    it('should let reported smart contract address retrieve compensation', async () => {
      await ethers.provider.send('evm_increaseTime', [
        Number(time.duration.minutes(5)),
      ]);

      await env.lssToken.connect(adr.lssInitialHolder)
        .transfer(adr.staker1.address, env.stakingAmount + env.stakingAmount);
      await env.lssToken.connect(adr.lssInitialHolder)
        .transfer(adr.staker2.address, env.stakingAmount * 2);
      await env.lssToken.connect(adr.lssInitialHolder)
        .transfer(adr.staker3.address, env.stakingAmount * 2);

      await env.lssToken.connect(adr.staker1)
        .approve(env.lssStaking.address, env.stakingAmount * 2);
      await env.lssToken.connect(adr.staker2)
        .approve(env.lssStaking.address, env.stakingAmount * 2);
      await env.lssToken.connect(adr.staker3)
        .approve(env.lssStaking.address, env.stakingAmount * 2);

      await ethers.provider.send('evm_increaseTime', [
        Number(time.duration.minutes(5)),
      ]);

      await env.lssStaking.connect(adr.staker1).stake(1);
      await env.lssStaking.connect(adr.staker2).stake(1);
      await env.lssStaking.connect(adr.staker3).stake(1);

      await env.lssGovernance.connect(adr.lssAdmin).resolveReport(1);

      expect(
        await env.lssGovernance.isReportSolved(1),
      ).to.be.equal(true);

      expect(
        await env.lssGovernance.reportResolution(1),
      ).to.be.equal(false);

     //************************** TEST BALANCE BEFORE *************************/
      console.log("Balance of Smart contract Before " , await env.lssToken.balanceOf(TestAddress.address));

     //************************** RETRIEVE COMPENSATION for smart contract *************************/   
      await expect(
        env.lssGovernance.connect(owner).retrieveCompensationForContracts(TestAddress.address),
      ).to.emit(env.lssGovernance, 'CompensationRetrieval').withArgs(
        TestAddress.address,
        20,
      );

      const compensationPercentage = await env.lssGovernance.compensationPercentage();

      //************************** TEST BALANCE AFTER *************************/
      console.log("Balance of Smart contract After " , await env.lssToken.balanceOf(TestAddress.address));


      expect(
        await env.lssToken.balanceOf(TestAddress.address),
      ).to.be.equal((env.reportingAmount * compensationPercentage) / 100);

    });


  //-------------------------------------------------------------------------------  

    it('should reject if EOA sent as input to retrieve compensation', async () => {
      await ethers.provider.send('evm_increaseTime', [
        Number(time.duration.minutes(5)),
      ]);

      await env.lssToken.connect(adr.lssInitialHolder)
        .transfer(adr.staker1.address, env.stakingAmount + env.stakingAmount);
      await env.lssToken.connect(adr.lssInitialHolder)
        .transfer(adr.staker2.address, env.stakingAmount * 2);
      await env.lssToken.connect(adr.lssInitialHolder)
        .transfer(adr.staker3.address, env.stakingAmount * 2);

      await env.lssToken.connect(adr.staker1)
        .approve(env.lssStaking.address, env.stakingAmount * 2);
      await env.lssToken.connect(adr.staker2)
        .approve(env.lssStaking.address, env.stakingAmount * 2);
      await env.lssToken.connect(adr.staker3)
        .approve(env.lssStaking.address, env.stakingAmount * 2);

      await ethers.provider.send('evm_increaseTime', [
        Number(time.duration.minutes(5)),
      ]);

      await env.lssStaking.connect(adr.staker1).stake(1);
      await env.lssStaking.connect(adr.staker2).stake(1);
      await env.lssStaking.connect(adr.staker3).stake(1);

      await env.lssGovernance.connect(adr.lssAdmin).resolveReport(1);

      expect(
        await env.lssGovernance.isReportSolved(1),
      ).to.be.equal(true);

      expect(
        await env.lssGovernance.reportResolution(1),
      ).to.be.equal(false);


      await expect(
        env.lssGovernance.connect(owner).retrieveCompensationForContracts(owner.address),
      ).to.be.revertedWith('LSS: Only contracts allowed');

    });
});
});