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
    function admin() external view returns (address);
}

interface ILssReporting {
    function getTokenFromReport(uint256 _reportId) external view returns (address);
    function getReportedAddress(uint256 _reportId) external view returns (address);
    function getReporter(uint256 _reportId) external view returns (address);
    function getReportTimestamps(uint256 _reportId) external view returns (uint256);
    function getReporterRewardAndLSSFee() external view returns (uint256 reward, uint256 fee);
    function getAmountReported(uint256 reportId) external view returns (uint256);
}

interface ILssController {
    function getStakeAmount() external view returns (uint256);
    function isBlacklisted(address _adr) external view returns (bool);
    function getReportLifetime() external view returns (uint256);
    function addToReportCoefficient(uint256 reportId, uint256 _amt) external;
    function getReportCoefficient(uint256 reportId) external view returns (uint256);
}

interface ILssGovernance {
    function reportResolution(uint256 reportId) external view returns(bool);
}

contract LosslessStaking is Initializable, ContextUpgradeable, PausableUpgradeable {

    uint256 public cooldownPeriod;

    struct Stake {
        uint256 reportId;
        uint256 timestamp;
        uint256 coefficient;
        bool payed;
    }

    ILERC20 public losslessToken;
    ILssReporting public losslessReporting;
    ILssController public losslessController;
    ILssGovernance public losslessGovernance;

    address public pauseAdmin;
    address public admin;
    address public recoveryAdmin;
    address public controllerAddress;
    address public governanceAddress;
    address public tokenAddress;

    mapping(address => bool) whitelist;
    
    mapping(address => Stake[]) public stakes;
    mapping(uint256 => address[]) public stakers;

    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event RecoveryAdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event PauseAdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event Staked(address indexed token, address indexed account, uint256 reportId);

    function initialize(address _admin, address _recoveryAdmin, address _pauseAdmin, address _losslessReporting, address _losslessController, address _losslessGovernance) public initializer {
       cooldownPeriod = 5 minutes;
       admin = _admin;
       recoveryAdmin = _recoveryAdmin;
       pauseAdmin = _pauseAdmin;
       losslessReporting = ILssReporting(_losslessReporting);
       losslessController = ILssController(_losslessController);
       losslessGovernance = ILssGovernance(_losslessGovernance);
       controllerAddress = _losslessController;
       governanceAddress = _losslessGovernance;
    }

    // --- MODIFIERS ---

    modifier onlyLosslessRecoveryAdmin() {
        require(_msgSender() == recoveryAdmin, "LSS: Must be recoveryAdmin");
        _;
    }

    modifier onlyLosslessAdmin() {
        require(admin == _msgSender(), "LSS: Must be admin");
        _;
    }

    modifier onlyLosslessPauseAdmin() {
        require(_msgSender() == pauseAdmin, "LSS: Must be pauseAdmin");
        _;
    }

    modifier notBlacklisted() {
        require(!losslessController.isBlacklisted(_msgSender()), "LSS: You cannot operate");
        _;
    }

    modifier onlyFromAdminOrLssSC {
        require(_msgSender() == controllerAddress ||
                _msgSender() == admin, "LSS: Admin or LSS SC only");
        _;
    }


    // --- SETTERS ---

    function pause() public onlyLosslessPauseAdmin {
        _pause();
    }    
    
    function unpause() public onlyLosslessPauseAdmin {
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

    function setILssReporting(address _losslessReporting) public onlyLosslessRecoveryAdmin {
        losslessReporting = ILssReporting(_losslessReporting);
    }

    function setLosslessToken(address _losslessToken) public onlyLosslessAdmin {
        losslessToken = ILERC20(_losslessToken);
        tokenAddress = _losslessToken;
    }
    
    // GET STAKE INFO

    function getAccountStakes(address account) public view returns(Stake[] memory) {
        return stakes[account];
    }

    function getStakingTimestamp(address _address, uint256 reportId) public view returns (uint256){
        for(uint256 i; i < stakes[_address].length; i++) {
            if (stakes[_address][i].reportId == reportId) {
                return stakes[_address][i].timestamp;
            }
        }
    }

    function getPayoutStatus(address _address, uint256 reportId) public view returns (bool) {
        for(uint256 i; i < stakes[_address].length; i++) {
            if (stakes[_address][i].reportId == reportId) {
                return stakes[_address][i].payed;
            }
        }
    }

    function getReportStakes(uint256 reportId) public view returns(address[] memory) {
        return stakers[reportId];
    }

    function getIsAccountStaked(uint256 reportId, address account) public view returns(bool) {
        for(uint256 i; i < stakes[account].length; i++) {
            if (stakes[account][i].reportId == reportId) {
                return true;
            }
        }

        return false;
    }


    // STAKING

    function calculateCoefficient(uint256 _timestamp) private view returns (uint256) {
        return  losslessController.getReportLifetime()/((block.timestamp - _timestamp));
    }

    function getStakerCoefficient(uint256 reportId, address _address) public view returns (uint256) {
        for(uint256 i; i < stakes[_address].length; i++) {
            if (stakes[_address][i].reportId == reportId) {
                return stakes[_address][i].coefficient;
            }
        }
    }

    function stake(uint256 reportId) public notBlacklisted {
        require(!getIsAccountStaked(reportId, _msgSender()), "LSS: already staked");
        require(losslessReporting.getReporter(reportId) != _msgSender(), "LSS: reporter can not stake");   

        uint256 reportTimestamp;
        reportTimestamp = losslessReporting.getReportTimestamps(reportId);

        require(reportTimestamp + 1 minutes < block.timestamp, "LSS: Must wait 1 minute to stake");
        require(reportId > 0 && (reportTimestamp + losslessController.getReportLifetime()) > block.timestamp, "LSS: report does not exists");

        uint256 stakeAmount = losslessController.getStakeAmount();
        require(losslessToken.balanceOf(_msgSender()) >= stakeAmount, "LSS: Not enough $LSS to stake");

        uint256 stakerCoefficient;
        stakerCoefficient = calculateCoefficient(reportTimestamp);

        stakers[reportId].push(_msgSender());
        stakes[_msgSender()].push(Stake(reportId, block.timestamp, stakerCoefficient, false));

        losslessController.addToReportCoefficient(reportId, stakerCoefficient);
        
        losslessToken.transferFrom(_msgSender(), address(this), stakeAmount);
        
        emit Staked(losslessReporting.getTokenFromReport(reportId), _msgSender(), reportId);
    }

    function addToWhitelist(address allowedAddress) public onlyLosslessAdmin {
        whitelist[allowedAddress] = true;
    }

    //function setPayoutStatus(uint256 reportId, address _adr) public onlyFromAdminOrLssSC {
    function setPayoutStatus(uint256 reportId, address _adr) private {
        for(uint256 i; i < stakes[_adr].length; i++) {
            if (stakes[_adr][i].reportId == reportId) {
                stakes[_adr][i].payed = true;
            }
        }
    }

    // --- CLAIM ---

    
    function reporterClaimableAmount(uint256 reportId) public view returns (uint256) {

        require(!getPayoutStatus(_msgSender(), reportId), "LSS: You already claimed");

        address reporter;
        reporter = losslessReporting.getReporter(reportId);

        require(_msgSender() == reporter, "LSS: Must be the reporter");

        uint256 reporterReward;
        uint256 losslessFee;
        uint256 amountStakedOnReport;
        uint256 stakeAmount;
        stakeAmount = losslessController.getStakeAmount();

        amountStakedOnReport = losslessReporting.getAmountReported(reportId);

        (reporterReward, losslessFee) = losslessReporting.getReporterRewardAndLSSFee();

        console.log("--------- Report %s ---------", reportId);
        console.log("Reporter is asking");
        console.log("Staker amount to claim: %s + %s", amountStakedOnReport * reporterReward / 10**2, stakeAmount);
        return amountStakedOnReport * reporterReward / 10**2;
    }
    
    function stakerClaimableAmount(uint256 reportId) public view returns (uint256) {

        require(!getPayoutStatus(_msgSender(), reportId), "LSS: You already claimed");
        require(getIsAccountStaked(reportId, _msgSender()), "LSS: You're not staking");

        uint256 reporterReward;
        uint256 losslessFee;
        uint256 amountStakedOnReport;
        uint256 stakerCoefficient;
        uint256 stakerPercentage;
        uint256 stakerAmountToClaim;
        uint256 secondsCoefficient;
        uint256 stakeAmount;
        uint256 reportCoefficient;
        address reportedToken;
        address reportedWallet;

        stakeAmount = losslessController.getStakeAmount();

        amountStakedOnReport = losslessReporting.getAmountReported(reportId);

        (reporterReward, losslessFee) = losslessReporting.getReporterRewardAndLSSFee();

        reportedToken = losslessReporting.getTokenFromReport(reportId);

        reportedWallet = losslessReporting.getReportedAddress(reportId);

        amountStakedOnReport = amountStakedOnReport * (100 - reporterReward - losslessFee) / 10**2;

        stakerCoefficient = getStakerCoefficient(reportId, _msgSender());
        reportCoefficient = losslessController.getReportCoefficient(reportId);

        secondsCoefficient = 10**4/reportCoefficient;

        stakerPercentage = (secondsCoefficient * stakerCoefficient);

        stakerAmountToClaim = (amountStakedOnReport * stakerPercentage) / 10**4;
        
        console.log("--------- Report %s ---------", reportId);
        console.log("Reported Token: %s", reportedToken);
        console.log("Reported Wallet: %s", reportedWallet);
        console.log("Total to distribute: %s", amountStakedOnReport);
        console.log("Report Coefficient: %s", reportCoefficient);
        console.log("Seconds coefficient: %s", secondsCoefficient);
        console.log("Current consulting staker: %s", _msgSender());
        console.log("Staker coefficient: %s", stakerCoefficient);
        console.log("Staker amount to claim: %s + %s", stakerAmountToClaim, stakeAmount);

        return stakerAmountToClaim;
    }


    function stakerClaim(uint256 reportId) public notBlacklisted{

        require( losslessReporting.getReporter(reportId) != _msgSender(), "LSS: Must user reporterClaim");
        require(!getPayoutStatus(_msgSender(), reportId), "LSS: You already claimed");
        require(losslessGovernance.reportResolution(reportId), "LSS: Report still open");

        uint256 amountToClaim;
        uint256 stakeAmount;

        amountToClaim = stakerClaimableAmount(reportId);
        stakeAmount = losslessController.getStakeAmount();

        console.log("Sending %s from rewards and %s from stakeAmount", amountToClaim, stakeAmount);

        ILERC20(losslessReporting.getTokenFromReport(reportId)).transfer(_msgSender(), amountToClaim);
        console.log("Sent reward");
        losslessToken.transfer( _msgSender(), stakeAmount);
        console.log("Sent stakeAmount");

        setPayoutStatus(reportId, _msgSender());
    }

    function reporterClaim(uint256 reportId) public notBlacklisted{
        
        require( losslessReporting.getReporter(reportId) == _msgSender(), "LSS: Must user stakerClaim");
        require(!getPayoutStatus(_msgSender(), reportId), "LSS: You already claimed");
        require(losslessGovernance.reportResolution(reportId), "LSS: Report still open");

        uint256 amountToClaim;
        uint256 stakeAmount;

        amountToClaim = reporterClaimableAmount(reportId);
        stakeAmount = losslessController.getStakeAmount();

        console.log("Sending %s from rewards and %s from stakeAmount", amountToClaim, stakeAmount);

        ILERC20(losslessReporting.getTokenFromReport(reportId)).transfer(_msgSender(), amountToClaim);
        console.log("Sent reward");
        losslessToken.transfer(_msgSender(), stakeAmount);
        console.log("Sent stakeAmount");

        setPayoutStatus(reportId, _msgSender());

    }

    // --- GETTERS ---

    function getVersion() public pure returns (uint256) {
        return 1;
    }
}