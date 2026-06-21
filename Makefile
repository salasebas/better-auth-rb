# Better Auth Ruby - Workspace Makefile
# Commands for working with every package in the monorepo.

BLUE := \033[36m
GREEN := \033[32m
YELLOW := \033[33m
NC := \033[0m

# =============================================
# INSTALLATION
# =============================================

.PHONY: install
install:
	bundle exec rake install
	@echo "$(GREEN)✓ All dependencies installed$(NC)"

.PHONY: setup
setup: install
	@echo "$(GREEN)✓ Workspace configured$(NC)"

# =============================================
# DEVELOPMENT
# =============================================

.PHONY: console
console:
	@echo "$(BLUE)💻 Opening workspace console...$(NC)"
	bundle exec irb -r bundler/setup -r better_auth -r better_auth/rails -r better_auth/sinatra -r better_auth/hanami

# =============================================
# LINTING
# =============================================

.PHONY: lint
lint:
	bundle exec rake lint
	@echo "$(GREEN)✓ Linting completed$(NC)"

.PHONY: lint-fix
lint-fix:
	bundle exec rake lint:fix
	@echo "$(GREEN)✓ Code fixed$(NC)"

# =============================================
# TESTING
# =============================================

.PHONY: test
test:
	@echo "$(BLUE)🧪 Running workspace tests...$(NC)"
	bundle exec rake ci

.PHONY: test-core
test-core:
	@echo "$(BLUE)🧪 Running better_auth tests...$(NC)"
	cd packages/better_auth && bundle exec rake test

.PHONY: test-rails
test-rails:
	@echo "$(BLUE)🧪 Running better_auth-rails tests...$(NC)"
	cd packages/better_auth-rails && bundle exec rspec

.PHONY: test-sinatra
test-sinatra:
	@echo "$(BLUE)🧪 Running better_auth-sinatra tests...$(NC)"
	cd packages/better_auth-sinatra && bundle exec rspec

.PHONY: test-hanami
test-hanami:
	@echo "$(BLUE)🧪 Running better_auth-hanami tests...$(NC)"
	cd packages/better_auth-hanami && bundle exec rspec

.PHONY: ci
ci:
	@echo "$(BLUE)🔧 Running full CI...$(NC)"
	bundle exec rake ci

# =============================================
# RELEASE
# =============================================

.PHONY: release-check
release-check:
	bundle exec rake release:check
	@echo "$(GREEN)✓ Build OK for all gems (local dry run)$(NC)"

# =============================================
# DATABASES
# =============================================

.PHONY: db-up
db-up:
	@echo "$(BLUE)🐳 Starting databases...$(NC)"
	docker compose up -d
	@echo "$(GREEN)✓ Databases ready$(NC)"

.PHONY: db-down
db-down:
	@echo "$(BLUE)🐳 Stopping databases...$(NC)"
	docker compose down
	@echo "$(GREEN)✓ Databases stopped$(NC)"

# =============================================
# CLEANUP
# =============================================

.PHONY: clean
clean:
	bundle exec rake clean
	@echo "$(GREEN)✓ Cleanup completed$(NC)"

# =============================================
# HELP
# =============================================

.PHONY: help
help:
	@echo "$(GREEN)Better Auth Ruby Workspace - Available commands:$(NC)"
	@echo ""
	@echo "$(YELLOW)Installation:$(NC)"
	@echo "  make install       - Install all dependencies"
	@echo "  make setup         - Initial setup"
	@echo ""
	@echo "$(YELLOW)Development:$(NC)"
	@echo "  make console       - Console with all packages loaded"
	@echo "  make lint          - Check style in all packages"
	@echo "  make lint-fix      - Fix style automatically"
	@echo ""
	@echo "$(YELLOW)Testing:$(NC)"
	@echo "  make test          - Tests for the whole workspace"
	@echo "  make test-core     - Only better_auth (core)"
	@echo "  make test-rails    - Only better_auth-rails"
	@echo "  make test-sinatra  - Only better_auth-sinatra"
	@echo "  make test-hanami   - Only better_auth-hanami"
	@echo "  make ci            - Full CI (lint + test)"
	@echo ""
	@echo "$(YELLOW)Release:$(NC)"
	@echo "  make release-check - Build gems without publishing (local dry run)"
	@echo ""
	@echo "$(YELLOW)Databases:$(NC)"
	@echo "  make db-up         - Start PostgreSQL, MySQL, Redis"
	@echo "  make db-down       - Stop containers"
	@echo ""
	@echo "$(YELLOW)Utilities:$(NC)"
	@echo "  make clean         - Clean temporary files"
	@echo "  make help          - Show this help"
