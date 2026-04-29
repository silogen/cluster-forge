.PHONY: deps bootstrap bootstrap-small bootstrap-medium dry-run check

PLAYBOOK = ansible-playbook bootstrap.yml

deps:
	ansible-galaxy collection install -r requirements.yml

bootstrap: deps
	$(PLAYBOOK) -e domain=$(DOMAIN)

bootstrap-small: deps
	$(PLAYBOOK) -e @vars/small-cluster.yml -e domain=$(DOMAIN)

bootstrap-medium: deps
	$(PLAYBOOK) -e @vars/example.yml -e cluster_size=medium -e domain=$(DOMAIN)

dry-run: deps
	$(PLAYBOOK) -e domain=$(DOMAIN) -e template_only=true

check:
	$(PLAYBOOK) -e domain=$(DOMAIN) --check
