import os
import subprocess
import json
from flask import Flask, send_file, jsonify, request

app = Flask(__name__)

SCRIPT_PATH = r"C:\BackupValidation\validate-backups.ps1"
REPORT_PATH = r"C:\BackupValidation\reports\dashboard_consolidated.html"

@app.route('/')
def dashboard():
    if not os.path.exists(REPORT_PATH):
        return """
        <html><body style="font-family:sans-serif;text-align:center;padding:50px;">
        <h2>Reporte no generado aún</h2>
        <p>Ejecute el script manualmente primero o use el botón de ejecución.</p>
        </body></html>
        """, 404
    return send_file(REPORT_PATH)

@app.route('/api/execute', methods=['POST'])
def execute_validation():
    try:
        data = request.get_json()
        target_db = data.get('db_name', 'all')
        force_docker = data.get('force_docker', False)
        
        args = ["powershell", "-ExecutionPolicy", "Bypass", "-File", SCRIPT_PATH]
        
        if target_db and target_db.lower() != 'all' and target_db.lower() != 'general':
            args.extend(["-TargetDB", target_db])
        
        # SIEMPRE forzar Docker cuando se ejecuta manualmente
        if force_docker:
            args.append("-ForceDocker")
            
        subprocess.Popen(
            args,
            creationflags=subprocess.CREATE_NO_WINDOW
        )
        return jsonify({
            "status": "success", 
            "message": f"Validación completa iniciada para: {target_db}"
        }), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/api/status', methods=['GET'])
def check_status():
    return jsonify({"status": "online"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)