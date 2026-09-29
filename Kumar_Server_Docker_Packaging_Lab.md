# Kumar Server — Docker Packaging Lab

## Goal

Package PostgreSQL as a Docker image using an RPM package.

Final architecture:

```text
PostgreSQL Source
        ↓
Kumar Server
        ↓
RPM
        ↓
Dockerfile
        ↓
Docker Image
        ↓
Docker Container
        ↓
Running PostgreSQL
        ↓
Verify Kumar Server
```

For initial Docker testing, an official PostgreSQL RPM can be used. Once the Kumar Server RPM is available, replace it with `kumar-postgresql-19.0-1.el9.x86_64.rpm`.

---

## 1. What can be tested with the official PostgreSQL RPM?

You can test all Docker mechanics using an official PostgreSQL RPM:

- Dockerfile
- RPM installation inside image
- Runtime dependencies
- PostgreSQL binary inside image
- `docker build`
- `docker run`
- Docker volume
- `initdb`
- PostgreSQL startup/shutdown
- `psql` connection
- Persistent PostgreSQL data
- Container logs
- Port mapping

Kumar-specific functionality requires the Kumar RPM:

- Kumar Server version string
- `bgwriter_delay = 500ms`
- `DUAL`
- `sysdate()`
- `kumar_query_delay`
- `kumar_index_advisor`

---

## 2. Check Docker

```bash
docker --version
docker info
```

---

## 3. Create the Docker lab directory

```bash
mkdir -p ~/kumar-docker
cd ~/kumar-docker
pwd
```

---

## 4. Put an RPM in the directory

For the first test, place an official PostgreSQL RPM in:

```text
~/kumar-docker/
```

Check:

```bash
ls -lh
```

The Docker build process does not care whether the RPM is official PostgreSQL or Kumar Server.

---

## 5. Inspect the RPM

```bash
rpm -ql <postgresql-server-rpm>
rpm -qpR <postgresql-server-rpm>
```

Confirm the actual PostgreSQL binary location before writing the `PATH` in the Dockerfile.

---

## 6. Build dependencies vs runtime dependencies

Build dependencies such as:

```text
gcc
make
bison
flex
perl
readline-devel
zlib-devel
libicu-devel
openssl-devel
```

are not necessarily required in the final runtime container.

The final image should contain runtime requirements, not the complete PostgreSQL build environment.

---

## 7. Initial Dockerfile using the official RPM

Create:

```bash
vi Dockerfile
```

Use:

```dockerfile
FROM rockylinux:9

LABEL name="PostgreSQL"       version="19"       description="PostgreSQL packaged from RPM"

COPY *.rpm /tmp/

RUN dnf install -y /tmp/*.rpm     && dnf clean all     && rm -f /tmp/*.rpm

ENV PGDATA="/var/lib/pgsql/data"
ENV PATH="/usr/pgsql-19/bin:${PATH}"

RUN useradd -r -m -U postgres     && mkdir -p "${PGDATA}"     && chown -R postgres:postgres "${PGDATA}"

USER postgres

EXPOSE 5432

VOLUME ["/var/lib/pgsql/data"]

CMD ["postgres", "-D", "/var/lib/pgsql/data"]
```

If your official RPM uses another installation path, change `/usr/pgsql-19/bin` accordingly.

---

## 8. Build the image

```bash
cd ~/kumar-docker
docker build -t postgres-rpm-test:19 .
```

Check:

```bash
docker images | grep postgres-rpm-test
```

---

## 9. Verify the PostgreSQL binary inside the image

```bash
docker run --rm postgres-rpm-test:19 postgres --version
```

Also:

```bash
docker run --rm postgres-rpm-test:19 psql --version
```

This proves:

```text
RPM
 ↓
Docker image
 ↓
PostgreSQL binaries
```

---

## 10. Create a Docker volume

```bash
docker volume create postgres-test-data
docker volume ls
```

---

## 11. First attempt to start PostgreSQL

```bash
docker run -d   --name postgres-test   -p 5432:5432   -v postgres-test-data:/var/lib/pgsql/data   postgres-rpm-test:19
```

Check:

```bash
docker ps
docker logs postgres-test
```

Because the data directory is empty, initialization may be required.

Remove the container:

```bash
docker rm -f postgres-test
```

---

## 12. Initialize the PostgreSQL cluster

```bash
docker run --rm   -v postgres-test-data:/var/lib/pgsql/data   postgres-rpm-test:19   initdb -D /var/lib/pgsql/data
```

Expected:

```text
Success. You can now start the database server.
```

---

## 13. Start PostgreSQL

```bash
docker run -d   --name postgres-test   -p 5432:5432   -v postgres-test-data:/var/lib/pgsql/data   postgres-rpm-test:19
```

Check:

```bash
docker ps
docker logs postgres-test
```

Look for:

```text
database system is ready to accept connections
```

---

## 14. Connect inside the container

```bash
docker exec -it postgres-test psql -U postgres
```

Test:

```sql
SELECT version();
SHOW port;
SELECT current_database();
SELECT current_user;
```

Exit:

```sql
\q
```

---

## 15. Connect from the host

If the host has `psql`:

```bash
psql -h localhost -p 5432 -U postgres
```

The mapping is:

```text
Host port 5432
      ↓
Container port 5432
```

---

## 16. Inspect the container and volume

```bash
docker ps
docker inspect postgres-test
docker volume inspect postgres-test-data
```

Architecture:

```text
Container
    │
    ▼
/var/lib/pgsql/data
    │
    ▼
Docker volume
    │
    ▼
postgres-test-data
```

---

## 17. Test persistence

Create a database:

```bash
docker exec -it postgres-test   psql -U postgres   -c "CREATE DATABASE testdb;"
```

Check:

```bash
docker exec -it postgres-test   psql -U postgres   -c "\l"
```

Stop and remove the container:

```bash
docker stop postgres-test
docker rm postgres-test
```

The volume remains:

```bash
docker volume ls
```

---

## 18. Start another container with the same volume

```bash
docker run -d   --name postgres-test2   -p 5432:5432   -v postgres-test-data:/var/lib/pgsql/data   postgres-rpm-test:19
```

Verify:

```bash
docker exec -it postgres-test2   psql -U postgres   -c "\l"
```

`testdb` should still exist.

This proves:

```text
Container destroyed
        ↓
Volume survives
        ↓
New container
        ↓
Same PostgreSQL data
```

Clean up:

```bash
docker stop postgres-test2
docker rm postgres-test2
docker volume rm postgres-test-data
```

---

# 19. Replace the official RPM with Kumar Server RPM

Once the Kumar RPM is available:

```text
kumar-postgresql-19.0-1.el9.x86_64.rpm
```

Place it in:

```text
~/kumar-docker/
```

For example:

```bash
cp /root/rpmbuild/RPMS/x86_64/kumar-postgresql-19.0-1.el9.x86_64.rpm    ~/kumar-docker/
```

Verify:

```bash
rpm -ql ~/kumar-docker/kumar-postgresql-19.0-1.el9.x86_64.rpm | head -50
```

Check dependencies:

```bash
rpm -qpR ~/kumar-docker/kumar-postgresql-19.0-1.el9.x86_64.rpm
```

---

# 20. Kumar Server Dockerfile

Use:

```dockerfile
FROM rockylinux:9

LABEL name="Kumar Server for PostgreSQL"       version="19.0"       description="Kumar Server for PostgreSQL 19beta4"

COPY kumar-postgresql-19.0-1.el9.x86_64.rpm /tmp/

RUN dnf install -y         /tmp/kumar-postgresql-19.0-1.el9.x86_64.rpm     && dnf clean all     && rm -f /tmp/kumar-postgresql-19.0-1.el9.x86_64.rpm

ENV PATH="/usr/pgsqlk-19/bin:${PATH}"
ENV PGDATA="/var/lib/pgsql/data"

RUN useradd -r -m -U postgres     && mkdir -p "${PGDATA}"     && chown -R postgres:postgres "${PGDATA}"     && chown -R postgres:postgres /usr/pgsqlk-19

USER postgres

EXPOSE 5432

VOLUME ["/var/lib/pgsql/data"]

CMD ["postgres", "-D", "/var/lib/pgsql/data"]
```

---

# 21. Verify the Kumar binary

Build:

```bash
docker build -t kumar-postgresql:19 .
```

Verify:

```bash
docker run --rm kumar-postgresql:19 postgres --version
```

Expected:

```text
postgres (PostgreSQL) 19beta4 - Kumar Server for PostgreSQL 19beta4
```

Also:

```bash
docker run --rm kumar-postgresql:19 psql --version
```

Expected:

```text
psql (19beta4 - Kumar Server for PostgreSQL 19beta4)
```

---

# 22. Create Kumar data volume

```bash
docker volume create kumar-pgdata
```

---

# 23. Initialize Kumar Server

```bash
docker run --rm   -v kumar-pgdata:/var/lib/pgsql/data   kumar-postgresql:19   initdb -D /var/lib/pgsql/data
```

---

# 24. Start Kumar Server

```bash
docker run -d   --name kumar-pg   -p 5432:5432   -v kumar-pgdata:/var/lib/pgsql/data   kumar-postgresql:19
```

Check:

```bash
docker ps
docker logs kumar-pg
```

Look for:

```text
database system is ready to accept connections
```

---

# 25. Connect to Kumar Server

```bash
docker exec -it kumar-pg psql -U postgres
```

---

# 26. Verify Kumar Server identity

```sql
SELECT version();
```

Expected:

```text
PostgreSQL 19beta4 - Kumar Server for PostgreSQL 19beta4
```

---

# 27. Verify bgwriter_delay

```sql
SHOW bgwriter_delay;
```

Expected:

```text
500ms
```

This proves:

```text
Source
  ↓
Build
  ↓
RPM
  ↓
Docker image
  ↓
Container
  ↓
Running PostgreSQL
```

---

# 28. Verify DUAL

```sql
SELECT * FROM dual;
```

Expected:

```text
 X
```

---

# 29. Verify sysdate()

```sql
SELECT sysdate();
SELECT sysdate() FROM dual;
```

---

# 30. Verify kumar_query_delay

```sql
SHOW kumar_query_delay;
```

Expected:

```text
0
```

Test:

```sql
	iming on

SET kumar_query_delay = '2s';

SELECT 10 + 20;
```

Expected execution time: approximately 2000 ms.

---

# 31. Verify Kumar extension

```sql
CREATE EXTENSION kumar_index_advisor;

SELECT * FROM kumar_unused_indexes();

SELECT * FROM kumar_duplicate_indexes();
```

---

# 32. Optional: automate initdb

Once the basic image works, create:

```bash
vi docker-entrypoint.sh
```

Use:

```bash
#!/bin/bash
set -e

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "Initializing Kumar Server..."
    initdb -D "$PGDATA"
fi

exec postgres -D "$PGDATA"
```

Make it executable:

```bash
chmod +x docker-entrypoint.sh
```

---

# 33. Final Kumar Dockerfile

```dockerfile
FROM rockylinux:9

LABEL name="Kumar Server for PostgreSQL"       version="19.0"       description="Kumar Server for PostgreSQL 19beta4"

COPY kumar-postgresql-19.0-1.el9.x86_64.rpm /tmp/

RUN dnf install -y         /tmp/kumar-postgresql-19.0-1.el9.x86_64.rpm     && dnf clean all     && rm -f /tmp/kumar-postgresql-19.0-1.el9.x86_64.rpm

ENV PATH="/usr/pgsqlk-19/bin:${PATH}"
ENV PGDATA="/var/lib/pgsql/data"

RUN useradd -r -m -U postgres     && mkdir -p "${PGDATA}"     && chown -R postgres:postgres "${PGDATA}"     && chown -R postgres:postgres /usr/pgsqlk-19

COPY docker-entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER postgres

EXPOSE 5432

VOLUME ["/var/lib/pgsql/data"]

ENTRYPOINT ["docker-entrypoint.sh"]
```

---

# 34. Build final image

```bash
docker build -t kumar-postgresql:19 .
```

Check:

```bash
docker images | grep kumar
```

---

# 35. Clean start

```bash
docker rm -f kumar-pg 2>/dev/null || true
docker volume rm kumar-pgdata 2>/dev/null || true
docker volume create kumar-pgdata
```

---

# 36. Start final Kumar Server container

```bash
docker run -d   --name kumar-pg   -p 5432:5432   -v kumar-pgdata:/var/lib/pgsql/data   kumar-postgresql:19
```

---

# 37. Watch initialization

```bash
docker logs -f kumar-pg
```

You should see:

```text
Initializing Kumar Server...
```

and eventually:

```text
database system is ready to accept connections
```

Press `Ctrl+C`; the container continues running.

---

# 38. Connect

```bash
docker exec -it kumar-pg psql -U postgres
```

---

# 39. Final verification

```sql
SELECT version();

SHOW bgwriter_delay;

SELECT * FROM dual;

SELECT sysdate();

SHOW kumar_query_delay;

CREATE EXTENSION kumar_index_advisor;

SELECT * FROM kumar_unused_indexes();

SELECT * FROM kumar_duplicate_indexes();
```

---

# 40. Useful Docker commands

## Containers

```bash
docker ps
docker ps -a
```

## Logs

```bash
docker logs kumar-pg
docker logs -f kumar-pg
```

## Enter PostgreSQL

```bash
docker exec -it kumar-pg psql -U postgres
```

## Execute SQL

```bash
docker exec kumar-pg   psql -U postgres   -c "SHOW bgwriter_delay;"
```

## Stop/start

```bash
docker stop kumar-pg
docker start kumar-pg
```

## Remove

```bash
docker rm -f kumar-pg
```

## Images

```bash
docker images
```

## Volumes

```bash
docker volume ls
```

## Inspect

```bash
docker inspect kumar-postgresql:19
docker volume inspect kumar-pgdata
```

---

# 41. Final architecture

```text
                 PostgreSQL 19 Source
                         |
                         v
                    Git / Patches
                         |
                         v
                  Source Changes
                         |
                         v
                  Build PostgreSQL
                         |
                         v
                    Kumar Server
                         |
                +--------+--------+
                |                 |
                v                 v
               RPM              Docker
                |                 |
                |             Dockerfile
                |                 |
                |                 v
                |          Docker Image
                |                 |
                |                 v
                |          Docker Container
                |                 |
                +--------+--------+
                         |
                         v
                 Running PostgreSQL
                         |
                         v
                Kumar Server Features
                         |
                         v
                  Final Verification
```

---

# 42. The final masterclass story

> We started with PostgreSQL source code.

```text
Source
  ↓
Git
  ↓
Modify
  ↓
Build
```

> Then we created our own PostgreSQL distribution.

```text
Kumar Server
```

> We packaged it for Linux.

```text
Kumar RPM
```

> Then we packaged that distribution into a container.

```text
Kumar Docker Image
```

> And finally we ran our own PostgreSQL distribution as a container.

```text
Docker Container
       ↓
Kumar Server
       ↓
PostgreSQL
```

The complete story:

```text
SOURCE
   ↓
BUILD
   ↓
CUSTOMIZE
   ↓
PACKAGE
   ↓
CONTAINERIZE
   ↓
RUN
   ↓
VERIFY
```

This gives the masterclass a complete end-to-end product-development story.
