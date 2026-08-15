.PHONY: up down logs ps seed smoke-test psql redis-cli es-health clean

up:
	./scripts/package_lambda.sh
	docker compose up -d
	./scripts/wait_for_localstack.sh
	./scripts/seed_elasticsearch.sh

down:
	docker compose down

logs:
	docker compose logs -f

ps:
	docker compose ps

seed:
	./scripts/package_lambda.sh
	docker compose exec localstack bash /etc/localstack/init/ready.d/01-init-aws.sh
	./scripts/seed_elasticsearch.sh

smoke-test:
	./scripts/smoke_test.sh

psql:
	docker compose exec postgres psql -U practice -d practice

redis-cli:
	docker compose exec redis redis-cli

es-health:
	curl -s "http://localhost:$${ES_PORT:-9200}/_cluster/health?pretty"

clean:
	docker compose down -v
	rm -rf ./volume/*
