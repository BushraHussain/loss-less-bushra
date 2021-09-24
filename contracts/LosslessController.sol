// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "hardhat/console.sol";

interface ILERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transferOutBlacklistedFunds(address[] calldata from) external;
    function admin() external view returns (address);
}

interface ILssStaking {
    function getReportStakes(uint256 reportId) external returns(address[] memory);
    function getIsAccountStaked(uint256 reportId, address account) external view returns(bool);
    function getStakingTimestamp(address _address, uint256 reportId) external view returns (uint256);
    function getPayoutStatus(address _address, uint256 reportId) external view returns (bool);
    function getStakerCoefficient(uint256 reportId, address _address) external view returns (uint256);
    function setPayoutStatus(uint256 reportId, address _adr) external;
}

interface ILssReporting {
    function getTokenFromReport(uint256 _reportId) external view returns (address);
    function getReportedAddress(uint256 _reportId) external view returns (address);
    function getReporter(uint256 _reportId) external view returns (address);
    function getReportTimestamps(uint256 _reportId) external view returns (uint256);
    function getReporterRewardAndLSSFee() external view returns (uint256 reward, uint256 fee);
    function getAmountReported(uint256 reportId) external view returns (uint256);
}

interface ILssGovernance {
    function reportResolution(uint256 reportId) external view returns(bool);
}


contract LosslessController is Initializable, ContextUpgradeable, PausableUpgradeable {
    address public pauseAdmin;
    address public admin;
    address public recoveryAdmin;

    uint256 public stakeAmount;
    uint256 public reportLifetime;

    uint256 public dexTranferThreshold;

    ILERC20 public losslessToken;
    ILssStaking public losslessStaking;
    ILssReporting public losslessReporting;
    ILssGovernance public losslessGovernance;

    address public losslessReportingAddress;
    address public losslessStakingingAddress;
    address public losslessGovernanceAddress;

    struct LocksQueue {
        mapping(uint256 => ReceiveCheckpoint) lockedFunds;
        uint256 touchedTimestamp;
        uint256 first;
        uint256 last;
    }

    struct TokenLockedFunds {
        mapping(address => LocksQueue) queue;
    }

    struct ReceiveCheckpoint {
        uint256 amount;
        uint256 timestamp;
    }

    mapping(address => TokenLockedFunds) private tokenScopedLockedFunds;

    mapping(uint256 => uint256) public reportCoefficient;
    
    mapping(address => bool) private dexList;
    mapping(address => bool) private whitelist;
    mapping(address => bool) private blacklist;

    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event RecoveryAdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event PauseAdminChanged(address indexed previousAdmin, address indexed newAdmin);

    // --- MODIFIERS ---

    modifier onlyLosslessRecoveryAdmin() {
        require(_msgSender() == recoveryAdmin, "LSS: Must be recoveryAdmin");
        _;
    }

    modifier onlyLosslessAdmin() {
        require(admin == _msgSender(), "LSS: Must be admin");
        _;
    }

    modifier onlyPauseAdmin() {
        require(_msgSender() == pauseAdmin, "LSS: Must be pauseAdmin");
        _;
    }

    modifier onlyFromAdminOrLssSC {
        require(_msgSender() == losslessStakingingAddress ||
                _msgSender() == losslessReportingAddress  || 
                _msgSender() == losslessGovernanceAddress ||
                _msgSender() == admin, "LSS: Admin or LSS SC only");
        _;
    }

    modifier notBlacklisted() {
        require(!blacklist[_msgSender()], "LSS: You cannot operate");
        _;
    }

    function initialize(address _admin, address _recoveryAdmin, address _pauseAdmin) public initializer {
        admin = _admin;
        recoveryAdmin = _recoveryAdmin;
        pauseAdmin = _pauseAdmin;
        dexTranferThreshold = 2;
    }

    // --- SETTERS ---

    function pause() public onlyPauseAdmin{
        _pause();
    }    
    
    function unpause() public onlyPauseAdmin{
        _unpause();
    }

    function setAdmin(address newAdmin) public onlyLosslessRecoveryAdmin {
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function setRecoveryAdmin(address newRecoveryAdmin) public onlyLosslessRecoveryAdmin {
        emit RecoveryAdminChanged(recoveryAdmin, newRecoveryAdmin);
        recoveryAdmin = newRecoveryAdmin;
    }

    function setPauseAdmin(address newPauseAdmin) public onlyLosslessRecoveryAdmin {
        emit PauseAdminChanged(pauseAdmin, newPauseAdmin);
        pauseAdmin = newPauseAdmin;
    }
    
    function setLosslessToken(address _losslessToken) public onlyLosslessAdmin {
        losslessToken = ILERC20(_losslessToken);
    }

    function addToDexList(address dexAddress) public onlyLosslessAdmin {
        dexList[dexAddress] = true;
    }

    function addToWhitelist(address _adr) public onlyLosslessAdmin {
        whitelist[_adr] = true;
    }

    function removeFromWhitelist(address _adr) public onlyLosslessAdmin {
        whitelist[_adr] = false;
    }

    function addToBlacklist(address _adr) public onlyFromAdminOrLssSC {
        require(!isBlacklisted(_adr), "LSS: Already blacklisted");
        blacklist[_adr] = true;
    }

    function removeFromBlacklist(address _adr) public onlyFromAdminOrLssSC{
        require(isBlacklisted(_adr), "LSS: Not blacklisted");
        blacklist[_adr] = false;
    }

    function resolvedNegatively(address _adr) public onlyFromAdminOrLssSC {
        removeFromBlacklist(_adr);
    }
    
    function setStakingContractAddress(address _adr) public onlyLosslessAdmin {
        losslessStaking = ILssStaking(_adr);
        losslessStakingingAddress = _adr;
    }

    function setReportingContractAddress(address _adr) public onlyLosslessAdmin {
        losslessReporting = ILssReporting(_adr);
        losslessReportingAddress = _adr;
    }

    function setGovernanceContractAddress(address _adr) public onlyLosslessAdmin {
        losslessGovernance = ILssGovernance(_adr);
        losslessGovernanceAddress = _adr;
    }

    function setStakeAmount(uint256 _stakeAmount) public onlyLosslessAdmin {
        stakeAmount = _stakeAmount;
    }

    function setReportLifetime(uint256 _lifetime) public onlyLosslessAdmin {
        reportLifetime = _lifetime;
    }

    function addToReportCoefficient(uint256 reportId, uint256 _amt) external onlyFromAdminOrLssSC {
        reportCoefficient[reportId] += _amt;
    }

    // --- GETTERS ---

    function getVersion() public pure returns (uint256) {
        return 1;
    }

    function isBlacklisted(address _adr) public view returns (bool) {
        return blacklist[_adr];
    }

    function isWhitelisted(address _adr) public view returns (bool) {
        return blacklist[_adr];
    }
    
    function getLockedAmount(address token, address account) public view returns (uint256) {
        uint256 lockedAmount;
        
        LocksQueue storage queue;
        queue = tokenScopedLockedFunds[token].queue[account];

        uint i = queue.first;
        while (i <= queue.last) {
            ReceiveCheckpoint memory checkpoint = queue.lockedFunds[i];
            if (checkpoint.timestamp > block.timestamp) {
                lockedAmount = lockedAmount + checkpoint.amount;
            }
            i += 1;
        }
        return lockedAmount;
    }

    function getAvailableAmount(address token, address account) public view returns (uint256 amount) {
        uint256 total = ILERC20(token).balanceOf(account);
        uint256 locked = getLockedAmount(token, account);
        console.log("total: %s locked: %s", total, locked);
        return total - locked;
    }

    function getQueueTail(address token, address account) public view returns (uint256) {
        LocksQueue storage queue;
        queue = tokenScopedLockedFunds[token].queue[account];
        return queue.last;
    }

    function getReportLifetime() public view returns (uint256) {
        return reportLifetime;
    }
    
    function getStakeAmount() public view returns (uint256) {
        return stakeAmount;
    }

    function getReportCoefficient(uint256 reportId) public view returns (uint256) {
        return reportCoefficient[reportId];
    }

    // LOCKs & QUEUES

    function removeExpiredLocks (address recipient) private {
        LocksQueue storage queue;
        queue = tokenScopedLockedFunds[_msgSender()].queue[recipient];

        uint i = queue.first;
        ReceiveCheckpoint memory checkpoint = queue.lockedFunds[i];

        while (checkpoint.timestamp <= block.timestamp && i <= queue.last) {
            delete queue.lockedFunds[i];
            i += 1;
            checkpoint = queue.lockedFunds[i];
        }
    }

    function removeUsedUpLocks (uint256 availableAmount, address account, uint256 amount) private {
        LocksQueue storage queue;
        queue = tokenScopedLockedFunds[_msgSender()].queue[account];

        require(queue.touchedTimestamp + 5 minutes <= block.timestamp, "LSS: Transfers limit reached");

        uint256 amountLeft = amount - availableAmount;
        uint i = 1;

        while (amountLeft > 0 && i <= queue.last) {
            ReceiveCheckpoint memory checkpoint;
            checkpoint = queue.lockedFunds[i];

            if ((checkpoint.timestamp - block.timestamp) >= 300)  {
                if (checkpoint.amount > amountLeft) {
                    checkpoint.amount -= amountLeft;
                    delete amountLeft;
                } else {
                    amountLeft -= checkpoint.amount;
                    delete checkpoint.amount;
                }
            }
            
            i += 1;
        }

        queue.touchedTimestamp = block.timestamp;
    }

    function enqueueLockedFunds(ReceiveCheckpoint memory checkpoint, address recipient) private {
        LocksQueue storage queue;
        queue = tokenScopedLockedFunds[_msgSender()].queue[recipient];

        if (queue.lockedFunds[queue.last].timestamp == checkpoint.timestamp) {
            queue.lockedFunds[queue.last].amount += checkpoint.amount;
        } else {
            queue.last += 1;
            queue.lockedFunds[queue.last] = checkpoint;
        }
    }

    function dequeueLockedFunds(address recipient) private {
        LocksQueue storage queue;
        queue = tokenScopedLockedFunds[_msgSender()].queue[recipient];

        delete queue.lockedFunds[queue.first];
        queue.first += 1;
    }

    // --- REPORT RESOLUTION ---

    function retreiveBlacklistedFunds(address[] calldata _addresses) public onlyFromAdminOrLssSC {
        uint256 blacklistedAmount;

        for(uint256 i; i < _addresses.length; i++) {
            blacklistedAmount += losslessToken.balanceOf(_addresses[i]);
            console.log("taking out %s from %s", blacklistedAmount, _addresses[i]);
        }
        losslessToken.transferOutBlacklistedFunds(_addresses);
    }

    function retrieveBlacklistedToStaking(uint256 reportId) public onlyFromAdminOrLssSC{
        uint256 retrieveAmount = losslessReporting.getAmountReported(reportId);
        losslessToken.transfer(losslessStakingingAddress, retrieveAmount);
    }
    
    /*
    function reporterClaimableAmount(uint256 reportId) public view returns (uint256) {

        require(!losslessStaking.getPayoutStatus(_msgSender(), reportId), "LSS: You already claimed");

        address reporter;
        reporter = losslessReporting.getReporter(reportId);

        require(_msgSender() == reporter, "LSS: Must be the reporter");

        uint256 reporterReward;
        uint256 losslessFee;
        uint256 amountStakedOnReport;

        amountStakedOnReport = losslessReporting.getAmountReported(reportId);

        (reporterReward, losslessFee) = losslessReporting.getReporterRewardAndLSSFee();

        console.log("--------- Report %s ---------", reportId);
        console.log("Reporter is asking");
        console.log("Staker amount to claim: %s + %s", amountStakedOnReport * reporterReward / 10**2, stakeAmount);
        return amountStakedOnReport * reporterReward / 10**2;
    }
    
    function stakerClaimableAmount(uint256 reportId) public view returns (uint256) {

        require(!losslessStaking.getPayoutStatus(_msgSender(), reportId), "LSS: You already claimed");
        require(losslessStaking.getIsAccountStaked(reportId, _msgSender()), "LSS: You're not staking");

        uint256 reporterReward;
        uint256 losslessFee;
        uint256 amountStakedOnReport;
        uint256 stakerCoefficient;
        uint256 stakerPercentage;
        uint256 stakerAmountToClaim;
        address reportedToken;
        address reportedWallet;
        uint256 secondsCoefficient;

        amountStakedOnReport = losslessReporting.getAmountReported(reportId);

        (reporterReward, losslessFee) = losslessReporting.getReporterRewardAndLSSFee();

        reportedToken = losslessReporting.getTokenFromReport(reportId);

        reportedWallet = losslessReporting.getReportedAddress(reportId);

        amountStakedOnReport = amountStakedOnReport * (100 - reporterReward - losslessFee) / 10**2;

        stakerCoefficient = losslessStaking.getStakerCoefficient(reportId, _msgSender());

        secondsCoefficient = 10**4/reportCoefficient[reportId];

        stakerPercentage = (secondsCoefficient * stakerCoefficient);

        stakerAmountToClaim = (amountStakedOnReport * stakerPercentage) / 10**4;
        
        console.log("--------- Report %s ---------", reportId);
        console.log("Reported Token: %s", reportedToken);
        console.log("Reported Wallet: %s", reportedWallet);
        console.log("Wallet Balance: %s", losslessReporting.getAmountReported(reportId));
        console.log("Total to distribute: %s", amountStakedOnReport);
        console.log("Report Coefficient: %s", reportCoefficient[reportId]);
        console.log("Seconds coefficient: %s", secondsCoefficient);
        console.log("Current consulting staker: %s", _msgSender());
        console.log("Staker coefficient: %s", stakerCoefficient);
        console.log("Staker amount to claim: %s + %s", stakerAmountToClaim, stakeAmount);

        return stakerAmountToClaim;
    }


    function stakerClaim(uint256 reportId) public notBlacklisted{

        require( losslessReporting.getReporter(reportId) != _msgSender(), "LSS: Must user reporterClaim");
        require(!losslessStaking.getPayoutStatus(_msgSender(), reportId), "LSS: You already claimed");
        require(losslessGovernance.reportResolution(reportId), "LSS: Report still open");

        uint256 amountToClaim;
        amountToClaim = stakerClaimableAmount(reportId);

        console.log("Sending %s from rewards and %s from stakeAmount", amountToClaim, stakeAmount);

        ILERC20(losslessReporting.getTokenFromReport(reportId)).transfer(_msgSender(), amountToClaim);
        console.log("Sent reward");
        losslessToken.transfer(_msgSender(), stakeAmount);
        console.log("Sent stakeAmount");

        losslessStaking.setPayoutStatus(reportId, _msgSender());

    }

        function reporterClaim(uint256 reportId) public notBlacklisted{
        
        require( losslessReporting.getReporter(reportId) == _msgSender(), "LSS: Must user stakerClaim");
        require(!losslessStaking.getPayoutStatus(_msgSender(), reportId), "LSS: You already claimed");
        require(losslessGovernance.reportResolution(reportId), "LSS: Report still open");

        uint256 amountToClaim;
        amountToClaim = reporterClaimableAmount(reportId);

        console.log("Sending %s from rewards and %s from stakeAmount", amountToClaim, stakeAmount);

        ILERC20(losslessReporting.getTokenFromReport(reportId)).transfer(_msgSender(), amountToClaim);
        console.log("Sent reward");
        losslessToken.transfer(_msgSender(), stakeAmount);
        console.log("Sent stakeAmount");

        losslessStaking.setPayoutStatus(reportId, _msgSender());

    }
*/

    // --- BEFORE HOOKS ---

    function beforeTransfer(address sender, address recipient, uint256 amount) external notBlacklisted {
        require(!isBlacklisted(sender), "LSS: You cannot operate");
        require(!isBlacklisted(recipient), "LSS: Recipient is blacklisted");

        uint256 availableAmount = getAvailableAmount(_msgSender(), sender);

        if (dexList[recipient] && amount > dexTranferThreshold) {
            require(availableAmount >= amount, "LSS: Amt exceeds settled balance");
        } else if (availableAmount < amount) {
            removeUsedUpLocks(availableAmount, sender, amount);
            require(getAvailableAmount(_msgSender(), sender) >= amount, "LSS: Amt exceeds settled balance");
        }
    }

    function beforeTransferFrom(address msgSender, address sender, address recipient, uint256 amount) external notBlacklisted {
        require(!isBlacklisted(sender), "LSS: You cannot operate");
        require(!isBlacklisted(recipient), "LSS: Recipient is blacklisted");

        console.log("msgSender() %s", _msgSender());

        uint256 availableAmount = getAvailableAmount(_msgSender(), sender);

        if (dexList[recipient]  && amount > dexTranferThreshold) {
            require(availableAmount >= amount, "LSS: Amt exceeds settled balance"); 
        } else if (availableAmount < amount) {
            removeUsedUpLocks(availableAmount, sender, amount);
            require(getAvailableAmount(_msgSender(), sender) >= amount, "LSS: Amt exceeds settled balance");
        }
    }

    function beforeApprove(address sender, address spender, uint256 amount) external {}

    function beforeIncreaseAllowance(address msgSender, address spender, uint256 addedValue) external {}

    function beforeDecreaseAllowance(address msgSender, address spender, uint256 subtractedValue) external {}

    // --- AFTER HOOKS ---

    function afterApprove(address sender, address spender, uint256 amount) external {}

    function afterTransfer(address sender, address recipient, uint256 amount) external {
        if (dexList[recipient]) {
            removeExpiredLocks(recipient);
        }
        ReceiveCheckpoint memory newCheckpoint = ReceiveCheckpoint(amount, block.timestamp + 5 minutes);
        enqueueLockedFunds(newCheckpoint, recipient);
    }

    function afterTransferFrom(address msgSender, address sender, address recipient, uint256 amount) external {
        removeExpiredLocks(recipient);
        ReceiveCheckpoint memory newCheckpoint = ReceiveCheckpoint(amount, block.timestamp + 5 minutes);
        enqueueLockedFunds(newCheckpoint, recipient);
    }

    function afterIncreaseAllowance(address sender, address spender, uint256 addedValue) external {}

    function afterDecreaseAllowance(address sender, address spender, uint256 subtractedValue) external {}
}