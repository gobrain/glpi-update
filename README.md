# GLPI Update Script

A simple Bash script to safely update a GLPI installation by:

* backing up the database
* backing up important instance directories
* downloading a new GLPI release
* replacing the application code
* restoring instance data
* running the GLPI database migration

The goal is to automate the standard manual update procedure while keeping the process transparent and recoverable.

---

## Features

* Automatic **database backup**
* Backup of important GLPI directories:

  * `config`
  * `files`
  * `plugins`
  * `marketplace`
* Download of a specified **GLPI release**
* Safe replacement of application code
* Automatic **database schema update**
* Optional rollback capability via code backup
* Configurable through a `.env` file

---

## Requirements

The script expects a typical Linux GLPI installation and requires the following tools:

* bash
* sudo
* wget
* tar
* rsync
* php
* mariadb-client or mysql-client

Install them if needed:

```bash
sudo apt install wget rsync mariadb-client
```

---

## Installation

Clone the repository:

```bash
git clone https://github.com/your-repository/glpi-update-script.git
cd glpi-update-script
```

Copy the example configuration file:

```bash
cp .env.example .env
```

Edit `.env` and adapt it to your environment.

---

## Configuration

The script reads configuration variables from the `.env` file.

Example:

```bash
NEW_VERSION_URL="https://github.com/glpi-project/glpi/releases/download/11.0.6/glpi-11.0.6.tgz"

GLPI_DIR="/var/www/glpi"
BACKUP_DIR="/var/backups/glpi"
TMP_DIR="/tmp/glpi_update"

DB_NAME="glpi"
DB_USER="glpi"

APACHE_USER="www-data"
GLPI_CONSOLE_USER="www-data"
```

### Database authentication

For security reasons it is recommended **not to store database passwords in the `.env` file**.

Instead create a `~/.my.cnf` file for the user executing the script:

```
[client]
user=glpi
password=your_password
```

Set secure permissions:

```bash
chmod 600 ~/.my.cnf
```

---

## Usage

Run the script:

```bash
sudo ./glpi-update.sh
```

The script will:

1. Backup the database
2. Backup important GLPI directories
3. Download the new GLPI version
4. Replace the application code
5. Restore instance data
6. Run the GLPI database update

---

## Backups

Backups are stored in:

```
/var/backups/glpi
```

Files created:

```
glpi_db_YYYYMMDD_HHMMSS.sql
glpi_files_YYYYMMDD_HHMMSS.tar.gz
glpi_code_YYYYMMDD_HHMMSS/
```

These allow restoring the instance if the update fails.

---

## Security notes

* Always test updates in a staging environment first.
* Ensure the backup directory has sufficient disk space.
* Verify that your GLPI plugins are compatible with the new version.
* Consider enabling GLPI maintenance mode before running the script.

---

## Recommended workflow

1. Enable GLPI maintenance mode
2. Run the script
3. Verify the update
4. Disable maintenance mode

---

## Troubleshooting

### Script fails with

```
/usr/bin/env: bash\r: No such file or directory
```

The script was saved with Windows line endings.

Fix with:

```bash
dos2unix glpi-update.sh
```

or

```bash
sed -i 's/\r$//' glpi-update.sh
```

---

## Disclaimer

This script is provided as-is.
Always verify backups and test updates before using in production environments.

---

## License

MIT License
