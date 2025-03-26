// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Crowdfunding {
    address public owner;
    uint256 public platformFeePercent;  // Fee in basis points (1% = 100 basis points)
    uint256 public totalCampaign = 0;
    uint256 public totalFounding = 0;
    uint256 public totalDonation = 0;
    uint256 public totalFeeCollected = 0;

    Campaign[] public campaigns;

    // Mapping from campaign ID to donor address to donation amount
    mapping(uint256 => mapping(address => uint256)) public donations;

    // Events for important contract actions
    event CampaignCreated(uint256 campaignId, string campaignName, address manager, uint256 goals);
    event DonationReceived(uint256 campaignId, address donor, uint256 amount);
    event FundsWithdrawn(uint256 campaignId, address manager, uint256 amount);
    event CampaignEnded(uint256 campaignId, bool successful);
    event RefundIssued(uint256 campaignId, address donor, uint256 amount);
    event FeeCollected(uint256 campaignId, uint256 feeAmount);
    event PlatformFeeChanged(uint256 newFeePercent);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    struct Campaign {
        string campaignName;
        address manager;
        uint256 minimumDonation;
        uint256 goals;
        uint endTime;
        uint256 totalDonation;
        uint256 totalDonor;
        bool isEnd;
        bool isFundsWithdrawn;
    }

    modifier campaignExists(uint256 _campaignId) {
        require(_campaignId < campaigns.length, "Campaign does not exist");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only contract owner can call this function");
        _;
    }

    modifier onlyManager(uint256 _campaignId) {
        require(msg.sender == campaigns[_campaignId].manager, "Only campaign manager can call this function");
        _;
    }

    modifier campaignActive(uint256 _campaignId) {
        require(!campaigns[_campaignId].isEnd, "Campaign has ended");
        require(block.timestamp < campaigns[_campaignId].endTime, "Campaign time has expired");
        _;
    }

    // Constructor to set the contract owner and platform fee
    constructor(uint256 _platformFeePercent) {
        require(_platformFeePercent <= 1000, "Fee cannot exceed 10%");
        owner = msg.sender;
        platformFeePercent = _platformFeePercent;
    }

    function createCampaign(
        string memory _campaignName,
        address _manager,
        uint256 _minimumDonation,
        uint256 _goals,
        uint _endTime
    ) public payable {
        require(_endTime > block.timestamp, "End time must be in the future");
        require(_goals > 0, "Goal must be greater than 0");
        require(_minimumDonation > 0, "Minimum donation must be greater than 0");
        // We require an initial donation (can be independent of minimum donation amount)
        require(msg.value > 0, "Must provide an initial donation to create a campaign");

        uint256 campaignId = totalCampaign;

        Campaign memory newCampaign = Campaign({
            campaignName: _campaignName,
            manager: _manager,
            minimumDonation: _minimumDonation,
            goals: _goals,
            endTime: _endTime,
            totalDonation: msg.value, // Initial donation from campaign creator
            totalDonor: 1, // Campaign creator is the first donor
            isEnd: false,
            isFundsWithdrawn: false
        });

        campaigns.push(newCampaign);
        totalCampaign++;
        totalDonation += msg.value;

        // Record the creator's donation
        donations[campaignId][msg.sender] = msg.value;

        emit CampaignCreated(campaignId, _campaignName, _manager, _goals);
        emit DonationReceived(campaignId, msg.sender, msg.value);
    }

    function donate(uint256 _campaignId) public payable campaignExists(_campaignId) campaignActive(_campaignId) {
        Campaign storage campaign = campaigns[_campaignId];

        require(msg.value >= campaign.minimumDonation, "Donation amount is less than minimum donation");

        // Update donation tracking if this is a new donor
        if (donations[_campaignId][msg.sender] == 0) {
            campaign.totalDonor++;
        }

        // Update donation amounts
        donations[_campaignId][msg.sender] += msg.value;
        campaign.totalDonation += msg.value;
        totalDonation += msg.value;

        emit DonationReceived(_campaignId, msg.sender, msg.value);

        // Check if campaign reached its goal
        if (campaign.totalDonation >= campaign.goals) {
            campaign.isEnd = true;
            emit CampaignEnded(_campaignId, true);
        }
    }

    function endCampaign(uint256 _campaignId) public campaignExists(_campaignId) onlyManager(_campaignId) {
        Campaign storage campaign = campaigns[_campaignId];

        require(!campaign.isEnd, "Campaign is already ended");

        campaign.isEnd = true;
        emit CampaignEnded(_campaignId, campaign.totalDonation >= campaign.goals);
    }

    function withdrawFunds(uint256 _campaignId) public campaignExists(_campaignId) onlyManager(_campaignId) {
        Campaign storage campaign = campaigns[_campaignId];

        require(campaign.isEnd, "Campaign must be ended before withdrawal");
        require(campaign.totalDonation >= campaign.goals, "Cannot withdraw funds if goal was not reached");
        require(!campaign.isFundsWithdrawn, "Funds have already been withdrawn");

        campaign.isFundsWithdrawn = true;

        // Calculate platform fee
        uint256 feeAmount = (campaign.totalDonation * platformFeePercent) / 10000;
        uint256 managerAmount = campaign.totalDonation - feeAmount;

        // Update totals
        totalFounding += managerAmount;
        totalFeeCollected += feeAmount;

        // Transfer funds to the campaign manager and fee to platform owner
        payable(campaign.manager).transfer(managerAmount);
        payable(owner).transfer(feeAmount);

        emit FundsWithdrawn(_campaignId, campaign.manager, managerAmount);
        emit FeeCollected(_campaignId, feeAmount);
    }

    function claimRefund(uint256 _campaignId) public campaignExists(_campaignId) {
        Campaign storage campaign = campaigns[_campaignId];

        require(campaign.isEnd, "Campaign must be ended before claiming refund");
        require(campaign.totalDonation < campaign.goals || block.timestamp > campaign.endTime,
            "Refunds only available if campaign fails or time expires");

        uint256 donationAmount = donations[_campaignId][msg.sender];
        require(donationAmount > 0, "No donations to refund");

        // Reset donation amount before transfer to prevent reentrancy
        donations[_campaignId][msg.sender] = 0;

        // Transfer refund to the donor
        payable(msg.sender).transfer(donationAmount);

        emit RefundIssued(_campaignId, msg.sender, donationAmount);
    }

    function getCampaign(uint256 _campaignId) public view campaignExists(_campaignId) returns (
        string memory campaignName,
        address manager,
        uint256 minimumDonation,
        uint256 goals,
        uint endTime,
        uint256 campaignDonationTotal,  // Changed variable name to avoid shadowing
        uint256 totalDonor,
        bool isEnd,
        bool isFundsWithdrawn
    ) {
        Campaign storage campaign = campaigns[_campaignId];

        return (
            campaign.campaignName,
            campaign.manager,
            campaign.minimumDonation,
            campaign.goals,
            campaign.endTime,
            campaign.totalDonation,
            campaign.totalDonor,
            campaign.isEnd,
            campaign.isFundsWithdrawn
        );
    }

    function getDonationAmount(uint256 _campaignId, address _donor) public view campaignExists(_campaignId) returns (uint256) {
        return donations[_campaignId][_donor];
    }

    function getTotalCampaigns() public view returns (uint256) {
        return totalCampaign;
    }

    // Owner functions for fee management
    function setPlatformFee(uint256 _newFeePercent) public onlyOwner {
        require(_newFeePercent <= 1000, "Fee cannot exceed 10%");
        platformFeePercent = _newFeePercent;
        emit PlatformFeeChanged(_newFeePercent);
    }

    function withdrawPlatformFees() public onlyOwner {
        uint256 contractBalance = address(this).balance;
        require(contractBalance > 0, "No funds to withdraw");

        payable(owner).transfer(contractBalance);
    }

    function transferOwnership(address _newOwner) public onlyOwner {
        require(_newOwner != address(0), "New owner cannot be the zero address");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    function getCampaignStatus(uint256 _campaignId) public view campaignExists(_campaignId) returns (
        bool isActive,
        bool isSuccessful,
        uint256 remainingTime,
        uint256 fundingProgress
    ) {
        Campaign storage campaign = campaigns[_campaignId];

        isActive = !campaign.isEnd && block.timestamp < campaign.endTime;
        isSuccessful = campaign.totalDonation >= campaign.goals;
        remainingTime = block.timestamp < campaign.endTime ? campaign.endTime - block.timestamp : 0;
        fundingProgress = campaign.goals > 0 ? (campaign.totalDonation * 100) / campaign.goals : 0;

        return (isActive, isSuccessful, remainingTime, fundingProgress);
    }
}