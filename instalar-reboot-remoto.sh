#!/bin/bash

# Sair imediatamente se um comando sair com um status diferente de zero.
set -e

# Variáveis
USERNAME="rebootuser"
SERVICE_DIR_NAME="reboot_service" # Nome da pasta dentro de /opt/
BASE_SERVICE_DIR="/opt"
FULL_SERVICE_DIR="${BASE_SERVICE_DIR}/${SERVICE_DIR_NAME}"
PYTHON_SCRIPT_NAME="reboot.py"
PYTHON_SCRIPT_PATH="${FULL_SERVICE_DIR}/${PYTHON_SCRIPT_NAME}"
SERVICE_NAME="reboot_server"
SERVICE_FILE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
SUDOERS_LINE="${USERNAME} ALL=(ALL) NOPASSWD:/sbin/reboot"
PYTHON_APP_PORT="5001"

# --- Funções Auxiliares ---
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERRO] $1" >&2
}

# --- Script Principal ---

log_info "Iniciando a configuração do serviço de reinicialização remota..."

# 0. Verificar se o script está sendo executado como root
if [ "$(id -u)" -ne 0 ]; then
   log_error "Este script deve ser executado como root ou com sudo."
   exit 1
fi

# 1. Instalar pacotes necessários (Python3, pip, Flask, Flask-CORS)
log_info "Instalando Python3, pip, Flask e Flask-CORS..."
if ! command -v python3 &> /dev/null || ! command -v pip3 &> /dev/null; then
    dnf install -y python3 python3-pip
    if [ $? -ne 0 ]; then
        log_error "Falha ao instalar python3 ou python3-pip."
        exit 1
    fi
else
    log_info "Python3 e pip3 já parecem estar instalados."
fi

pip3 install Flask Flask-CORS
log_info "Dependências verificadas/instaladas."


# 2. Criar o usuário
if id "${USERNAME}" &>/dev/null; then
    log_info "O usuário ${USERNAME} já existe."
else
    log_info "Criando usuário ${USERNAME}..."
    useradd -m -r -s /sbin/nologin "${USERNAME}" # -r para usuário de sistema, -s /sbin/nologin por segurança
    if [ $? -ne 0 ]; then
        log_error "Falha ao criar o usuário ${USERNAME}."
        exit 1
    fi
    log_info "Usuário ${USERNAME} criado com sucesso."
fi

# 3. Adicionar usuário ao sudoers para o comando de reinicialização
log_info "Configurando sudoers para ${USERNAME}..."
# Criar um arquivo em /etc/sudoers.d/ é a maneira mais segura e gerenciável
SUDOERS_FILE="/etc/sudoers.d/91-${USERNAME}-reboot"
if [ -f "${SUDOERS_FILE}" ] && grep -Fxq "${SUDOERS_LINE}" "${SUDOERS_FILE}"; then
    log_info "A entrada sudoers para ${USERNAME} já existe em ${SUDOERS_FILE}."
else
    echo "${SUDOERS_LINE}" > "${SUDOERS_FILE}"
    chmod 0440 "${SUDOERS_FILE}"
    log_info "Adicionada '${SUDOERS_LINE}' a ${SUDOERS_FILE}."
    # Verificar a sintaxe do arquivo sudoers (opcional, mas bom)
    visudo -cf "${SUDOERS_FILE}"
    if [ $? -ne 0 ]; then
        log_error "Erro de sintaxe no arquivo sudoers ${SUDOERS_FILE}. Removendo..."
        rm -f "${SUDOERS_FILE}"
        exit 1
    fi
fi

# 4. Criar o diretório do serviço
log_info "Criando diretório ${FULL_SERVICE_DIR}..."
mkdir -p "${FULL_SERVICE_DIR}"
if [ $? -ne 0 ]; then
    log_error "Falha ao criar o diretório ${FULL_SERVICE_DIR}."
    exit 1
fi

# 5. Criar o script Python
log_info "Criando script Python ${PYTHON_SCRIPT_PATH}..."
cat > "${PYTHON_SCRIPT_PATH}" << EOF
import os
import subprocess
import time
import threading
from flask import Flask, jsonify, request, Response
from flask_cors import CORS
from datetime import datetime

app = Flask(__name__)
CORS(app)

# Configurações de Segurança
AUTHORIZED_USERNAME = "next_console_1"
AUTHORIZED_PASSWORD = "yas789fu90123o"
AUTHORIZED_TOKEN = "tokennext"

# Diretório de logs
LOG_DIR = '/opt/reboot_service'
os.makedirs(LOG_DIR, exist_ok=True)

def calcular_senha_do_dia():
    hoje = datetime.now()
    return hoje.day * hoje.month * (hoje.year % 100) * 3

def check_auth(username, password):
    return username == AUTHORIZED_USERNAME and password == AUTHORIZED_PASSWORD

def authenticate():
    return Response(
        'Acesso não autorizado',
        401,
        {'WWW-Authenticate': 'Basic realm="Login Required"'}
    )

def coletar_recursos_simples():
    """
    Retorna uma string "CPU: xx.x%  RAM: xx.x%  SWAP: xx.x%" 
    usando saída de `top -b -n1` e `free -m`.
    """
    # 1) CPU
    top_out = subprocess.run(
        ['top','-b','-n','1'], capture_output=True, text=True
    ).stdout.splitlines()
    cpu_line = next((l for l in top_out if 'Cpu(s)' in l), "")
    cpu_used = 0.0
    if cpu_line:
        try:
            parts = cpu_line.split(':')[1].split(',')
            us = float(parts[0].strip().split()[0])
            sy = float(parts[1].strip().split()[0])
            cpu_used = us + sy
        except:
            pass

    # 2) Memória e Swap
    free_out = subprocess.run(
        ['free','-m'], capture_output=True, text=True
    ).stdout.splitlines()
    mem_vals  = free_out[1].split() if len(free_out) > 1 else ["Mem:",0,0,0]
    swap_vals = free_out[2].split() if len(free_out) > 2 else ["Swap:",0,0,0]
    ram_pct = swap_pct = 0.0
    try:
        mem_total = float(mem_vals[1]); mem_used = float(mem_vals[2])
        ram_pct = (mem_used / mem_total) * 100
    except:
        pass
    try:
        swap_total = float(swap_vals[1]); swap_used = float(swap_vals[2])
        swap_pct = (swap_used / swap_total) * 100 if swap_total > 0 else 0.0
    except:
        pass

    return f"CPU: {cpu_used:.1f}%  RAM: {ram_pct:.1f}%  SWAP: {swap_pct:.1f}%"

def coletar_status_servico(nome_servico: str) -> str:
    """
    Executa `systemctl status <nome_servico> --no-pager` e retorna
    a saída como string (stdout ou stderr).
    """
    try:
        resultado = subprocess.run(
            ['systemctl', 'status', nome_servico, '--no-pager'],
            capture_output=True,
            text=True
        )
        return resultado.stdout or resultado.stderr
    except Exception as e:
        return f"Erro ao coletar status de {nome_servico}: {e}"

def gravar_log(motivo: str):
    now = datetime.now()
    fn = f"ReinicioRemoto_{now.strftime('%Y%m%d_%H%M%S')}.log"
    path = os.path.join(LOG_DIR, fn)
    resumo = coletar_recursos_simples()
    status_app = coletar_status_servico("app")
    status_pg  = coletar_status_servico("postgresql-13")

    with open(path, 'w') as f:
        f.write(f"Data/Hora: {now.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"Motivo: {motivo}\n\n")
        f.write(f"=== Recursos ===\n{resumo}\n\n")
        f.write("=== Status do serviço 'app' ===\n")
        f.write(status_app + "\n")
        f.write("=== Status do serviço 'postgresql-13' ===\n")
        f.write(status_pg + "\n")

def reboot_now():
    """Espera 1s e dispara o reboot real."""
    time.sleep(1)
    subprocess.run(["sudo", "reboot"], check=True)

@app.route('/', methods=['GET'])
def index():
    return jsonify({"status": "Serviço ativo"}), 200

@app.route('/reboot', methods=['POST'])
def reboot_endpoint():
    # 1) Autenticação Básica
    auth = request.authorization
    if not auth or not check_auth(auth.username, auth.password):
        return authenticate()

    # 2) Token no Header
    if request.headers.get('X-API-Token') != AUTHORIZED_TOKEN:
        return jsonify({"error": "Token inválido"}), 401

    # 3) Senha Técnica + Motivo no Corpo
    data = request.get_json(silent=True) or {}
    if 'password' not in data or 'reason' not in data:
        return jsonify({"error": "Senha técnica e motivo são obrigatórios"}), 400

    if data['password'] != calcular_senha_do_dia():
        return jsonify({"error": "Senha técnica inválida"}), 401

    motivo = data['reason']

    # 4) Grava o log sincrono antes de reiniciar
    try:
        gravar_log(motivo)
    except Exception as e:
        return jsonify({"error": f"Falha ao gravar log: {e}"}), 500

    # 5) Agenda reboot em background e responde imediatamente
    threading.Thread(target=reboot_now, daemon=True).start()
    return jsonify({"status": "Reinicialização agendada"}), 200

if __name__ == '__main__':
    # Apache fará o TLS, não precisa de ssl_context aqui
    app.run(host='0.0.0.0', port=5001)

EOF

if [ $? -ne 0 ]; then
    log_error "Falha ao criar o script Python ${PYTHON_SCRIPT_PATH}."
    exit 1
fi
log_info "Script Python criado."

# 6. Definir propriedade e permissões para o diretório do serviço e script
log_info "Definindo propriedade de ${FULL_SERVICE_DIR} para ${USERNAME}:${USERNAME}..."
chown -R "${USERNAME}:${USERNAME}" "${FULL_SERVICE_DIR}"
chmod 750 "${FULL_SERVICE_DIR}"
chmod 750 "${PYTHON_SCRIPT_PATH}" # u+rwx, g+rx
log_info "Propriedade e permissões definidas."

# 7. Criar o arquivo de serviço systemd
log_info "Criando arquivo de serviço systemd ${SERVICE_FILE_PATH}..."
cat > "${SERVICE_FILE_PATH}" << EOF
[Unit]
Description=Reboot Servidor Grafana
After=network.target network-online.target
Wants=network-online.target

[Service]
User=${USERNAME}
Group=${USERNAME}

WorkingDirectory=${FULL_SERVICE_DIR}
ExecStart=/usr/bin/python3 ${PYTHON_SCRIPT_PATH}
Restart=on-failure
RestartSec=5s

# Para logging, você pode redirecionar a saída padrão e de erro para arquivos ou usar journald
# StandardOutput=append:/var/log/${SERVICE_NAME}.log
# StandardError=append:/var/log/${SERVICE_NAME}.err.log
# Ou, se preferir usar o journal do systemd (recomendado):
StandardOutput=journal
StandardError=journal

# Fortalecimento de segurança (opcional, mas recomendado para serviços de produção)
# PrivateTmp=true
# ProtectSystem=full
# NoNewPrivileges=true
# PrivateDevices=true
# ProtectHome=true # Se o usuário não precisar de acesso à home
# ReadWritePaths=${FULL_SERVICE_DIR} # Permite escrita apenas no diretório de trabalho (e logs se configurado)

[Install]
WantedBy=multi-user.target
EOF

# Configuração do Apache.

# Caminho do arquivo a ser alterado
FILE="/etc/httpd/conf.d/app-le-ssl.conf"

# Verifica se o arquivo existe
if [ ! -f "$FILE" ]; then
  echo "Arquivo não encontrado: $FILE"
  exit 1
fi

# Faz backup com timestamp
cp "$FILE" "${FILE}.bak.$(date +%Y%m%d_%H%M%S)"

# Insere as linhas nas posições 3 e 4
# (o sed -i insere antes da linha indicada)
sed -i '3i ProxyPass        /reboot http://localhost:5001/reboot'    "$FILE"
sed -i '4i ProxyPassReverse /reboot http://localhost:5001/reboot'    "$FILE"

echo "Linhas inseridas em $FILE (backup em ${FILE}.bak.*)"

if [ $? -ne 0 ]; then
    log_error "Falha ao criar o arquivo de serviço systemd ${SERVICE_FILE_PATH}."
    exit 1
fi
chmod 644 "${SERVICE_FILE_PATH}" # Permissão padrão para arquivos de unidade systemd
log_info "Arquivo de serviço systemd criado."

# 8. Recarregar systemd, habilitar e iniciar o serviço
log_info "Recarregando o daemon systemd..."
systemctl daemon-reload
if [ $? -ne 0 ]; then
    log_error "Falha ao recarregar o daemon systemd."
    exit 1
fi

log_info "Habilitando o serviço ${SERVICE_NAME} para iniciar no boot..."
systemctl enable "${SERVICE_NAME}"
if [ $? -ne 0 ]; then
    log_error "Falha ao habilitar o serviço ${SERVICE_NAME}."
    exit 1
fi

log_info "Iniciando o serviço ${SERVICE_NAME}..."
systemctl start "${SERVICE_NAME}"
if [ $? -ne 0 ]; then
    log_error "Falha ao iniciar o serviço ${SERVICE_NAME}. Verifique o status com 'systemctl status ${SERVICE_NAME}' e os logs com 'journalctl -u ${SERVICE_NAME}'"
    # Se StandardOutput/Error foi para arquivos: /var/log/${SERVICE_NAME}.log e .err.log
    exit 1
fi

log_info "Serviço ${SERVICE_NAME} iniciado."
# Exibir status rapidamente
systemctl status "${SERVICE_NAME}" --no-pager

systemctl restart httpd

log_info "--- Configuração Concluída ---"
log_info "O serviço de reinicialização deve estar em execução e acessível na porta ${PYTHON_APP_PORT}."
log_info "Você pode testar com: curl -X POST -u admin:admin http://<ip_do_seu_servidor>:${PYTHON_APP_PORT}/reboot"
log_info "Lembre-se de alterar as credenciais padrão em ${PYTHON_SCRIPT_PATH} por segurança!"
log_info "Logs para o serviço podem ser vistos com: journalctl -u ${SERVICE_NAME} -f"

exit 0
