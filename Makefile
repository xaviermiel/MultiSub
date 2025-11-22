.PHONY: all test clean deploy

# Load environment variables from .env file
include .env
export

# Default target
all: clean install build test

# Install dependencies
install:
	forge install foundry-rs/forge-std

# Build the project
build:
	forge build

# Run tests
test:
	forge test -vv

# Run tests with gas reporting
test-gas:
	forge test --gas-report

# Run tests with coverage
coverage:
	forge coverage

# Clean build artifacts
clean:
	forge clean

# Format code
format:
	forge fmt

# Deploy to Sepolia
deploy-sepolia:
	@echo "Deploying to Sepolia..."
	forge script script/DeployDeFiModule.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		-vvvv

# Setup roles and permissions
setup-roles:
	@echo "Setting up roles..."
	forge script script/SetupDeFiModule.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		-vvvv

# Verify contracts
verify:
	@echo "Verifying contracts..."
	forge verify-contract \
		$(DEFI_MODULE_ADDRESS) \
		src/DeFiInteractorModule.sol:DeFiInteractorModule \
		--chain-id 11155111 \
		--constructor-args $(shell cast abi-encode "constructor(address,address)" $(SAFE_ADDRESS) $(SAFE_ADDRESS))

# Run local node for testing
anvil:
	anvil

# Help
help:
	@echo "Available commands:"
	@echo "  make install         - Install dependencies"
	@echo "  make build           - Build contracts"
	@echo "  make test            - Run tests"
	@echo "  make test-gas        - Run tests with gas reporting"
	@echo "  make coverage        - Generate coverage report"
	@echo "  make clean           - Clean build artifacts"
	@echo "  make format          - Format code"
	@echo "  make deploy-sepolia  - Deploy DeFiInteractorModule to Sepolia testnet"
	@echo "  make setup-roles     - Setup roles and permissions for DeFi module"
	@echo "  make verify          - Verify contracts on Etherscan"
	@echo "  make anvil           - Run local test node"
