PLAYBOOK_INSTALL := install.yml
PLAYBOOK_UNINSTALL := uninstall.yml

.PHONY: install clean remove uninstall test test-playbooks

VENV ?= .venv

ANSIBLE_PLAYBOOK := $(if $(wildcard $(VENV)/bin/ansible-playbook),$(abspath $(VENV))/bin/ansible-playbook,ansible-playbook)
MOLECULE := $(if $(wildcard $(VENV)/bin/molecule),$(abspath $(VENV))/bin/molecule,molecule)
ANSIBLE_PYTHON_INTERPRETER := $(if $(wildcard $(VENV)/bin/python),$(abspath $(VENV))/bin/python,)

install:
	@echo "Installing S2T (recommended setup) using Ansible..."
	ANSIBLE_PYTHON_INTERPRETER="$(ANSIBLE_PYTHON_INTERPRETER)" $(ANSIBLE_PLAYBOOK) -i "localhost," -c local $(PLAYBOOK_INSTALL)

clean: remove

remove:
	@echo "Uninstalling S2T Role..."
	ANSIBLE_PYTHON_INTERPRETER="$(ANSIBLE_PYTHON_INTERPRETER)" $(ANSIBLE_PLAYBOOK) -i "localhost," -c local $(PLAYBOOK_UNINSTALL)

uninstall: remove

test:
	@echo "Running Molecule tests (requires docker & molecule)..."
	@echo "Running playbook checks..."
	VENV="$(VENV)" ./scripts/check_playbooks.sh
	cd s2t-role && PATH="$(abspath $(VENV))/bin:$$PATH" $(MOLECULE) test

test-playbooks:
	@echo "Running playbook checks..."
	VENV="$(VENV)" ./scripts/check_playbooks.sh
