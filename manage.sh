#!/bin/bash

# Management script for Organization Stack

set -e

# Load configuration
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

# Remote execution wrapper
remote_exec() {
    if [ -n "$REMOTE_HOST" ] && [ -n "$REMOTE_USER" ]; then
        ssh -p ${REMOTE_PORT:-22} ${REMOTE_USER}@${REMOTE_HOST} "cd ~/${REMOTE_DIR:-org-stack} && $1"
    else
        eval "$1"
    fi
}

function show_help {
    cat << EOF
Organization Stack Management Script

Usage: ./manage.sh [command]

Commands:
    start       Start all services
    stop        Stop all services
    restart     Restart all services
    status      Show status of all services
    logs        Show logs (add service name to filter: ./manage.sh logs gitea)
    update      Pull latest images and restart
    backup      Backup all volumes
    restore     Restore from backup
    reset       Stop and remove all containers and volumes (DESTRUCTIVE!)
    
Examples:
    ./manage.sh start
    ./manage.sh logs authelia
    ./manage.sh backup
EOF
}

function start_services {
    echo "Starting services..."
    remote_exec "docker compose up -d"
    echo "✓ Services started"
    if [ -n "$BASE_DOMAIN" ]; then
        echo ""
        echo "Access points:"
        echo "  - Gitea: https://git.${BASE_DOMAIN}"
        echo "  - Wiki: https://wiki.${BASE_DOMAIN}"
        echo "  - Authelia: https://auth.${BASE_DOMAIN}"
        echo "  - lldap: https://ldap.${BASE_DOMAIN}"
    fi
}

function stop_services {
    echo "Stopping services..."
    remote_exec "docker compose stop"
    echo "✓ Services stopped"
}

function restart_services {
    echo "Restarting services..."
    remote_exec "docker compose restart"
    echo "✓ Services restarted"
}

function show_status {
    remote_exec "docker compose ps"
}

function show_logs {
    if [ -z "$1" ]; then
        remote_exec "docker compose logs -f --tail=100"
    else
        remote_exec "docker compose logs -f --tail=100 $1"
    fi
}

function update_services {
    echo "Pulling latest images..."
    remote_exec "docker compose pull"
    echo ""
    echo "Restarting services..."
    remote_exec "docker compose up -d"
    echo "✓ Services updated"
}

function backup_volumes {
    BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    echo "Creating backup in $BACKUP_DIR..."
    
    # Backup each volume
    for volume in lldap_data authelia_data gitea_data jspwiki_data; do
        echo "Backing up $volume..."
        docker run --rm \
            -v "org-stack_${volume}:/data" \
            -v "$(pwd)/$BACKUP_DIR:/backup" \
            alpine \
            tar czf "/backup/${volume}.tar.gz" -C /data .
    done
    
    echo "✓ Backup completed: $BACKUP_DIR"
}

function restore_volumes {
    echo "Available backups:"
    ls -1d ./backups/*/ 2>/dev/null || echo "No backups found"
    echo ""
    read -p "Enter backup directory name (e.g., backups/20240101_120000): " BACKUP_DIR
    
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "❌ Backup directory not found"
        exit 1
    fi
    
    read -p "⚠️  This will overwrite current data. Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Restore cancelled"
        exit 1
    fi
    
    echo "Stopping services..."
    docker compose stop

    for volume in lldap_data authelia_data gitea_data jspwiki_data; do
        if [ -f "$BACKUP_DIR/${volume}.tar.gz" ]; then
            echo "Restoring $volume..."
            docker run --rm \
                -v "org-stack_${volume}:/data" \
                -v "$(pwd)/$BACKUP_DIR:/backup" \
                alpine \
                sh -c "rm -rf /data/* && tar xzf /backup/${volume}.tar.gz -C /data"
        fi
    done

    echo "Starting services..."
    docker compose start
    echo "✓ Restore completed"
}

function reset_everything {
    echo "⚠️  WARNING: This will remove all containers, volumes, and data!"
    read -p "Type 'yes' to confirm: " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo "Reset cancelled"
        exit 1
    fi

    echo "Stopping and removing everything..."
    remote_exec "docker compose down -v"
    echo "✓ Everything removed"
    echo ""
    echo "To start fresh, run:"
    echo "  ./deploy.sh"
}

# Main script
case "${1:-}" in
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        restart_services
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs "${2:-}"
        ;;
    update)
        update_services
        ;;
    backup)
        backup_volumes
        ;;
    restore)
        restore_volumes
        ;;
    reset)
        reset_everything
        ;;
    help|--help|-h|"")
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
