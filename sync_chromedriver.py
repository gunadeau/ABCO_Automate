#!/usr/bin/env python3
"""
Script pour forcer la synchronisation ChromeDriver avec la version exacte de Chrome
"""

import subprocess
import re
import os
import shutil
import sys
import logging

# Configuration du logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def get_chrome_version():
    """Récupère la version exacte de Chrome installée"""
    try:
        result = subprocess.run(['google-chrome', '--version'], 
                              capture_output=True, text=True, check=True)
        version_match = re.search(r'(\d+)\.(\d+)\.(\d+)\.(\d+)', result.stdout)
        if version_match:
            full_version = version_match.group(0)
            major_version = int(version_match.group(1))
            logging.info(f"Chrome version détectée: {full_version}")
            return major_version, full_version
        else:
            raise ValueError("Impossible de parser la version de Chrome")
    except Exception as e:
        logging.error(f"Erreur lors de la détection de Chrome: {e}")
        raise

def force_chrome_binary_path():
    """Force l'utilisation du bon binaire Chrome"""
    chrome_paths = [
        '/usr/bin/google-chrome',
        '/usr/bin/google-chrome-stable',
        '/opt/google/chrome/chrome'
    ]
    
    for path in chrome_paths:
        if os.path.exists(path):
            logging.info(f"Chrome binaire trouvé: {path}")
            # Vérifier la version de ce binaire
            try:
                result = subprocess.run([path, '--version'], 
                                      capture_output=True, text=True, check=True)
                logging.info(f"Version de {path}: {result.stdout.strip()}")
                return path
            except Exception as e:
                logging.warning(f"Erreur avec {path}: {e}")
                continue
    
    return None

def clear_all_chrome_caches():
    """Nettoie tous les caches liés à Chrome et ChromeDriver"""
    cache_dirs = [
        os.path.expanduser('~/.local/share/undetected_chromedriver'),
        os.path.expanduser('~/.cache/selenium'),
        '/tmp/chrome_*',
    ]
    
    for cache_dir in cache_dirs:
        if '*' in cache_dir:
            # Utiliser shell pour les wildcards
            subprocess.run(f'rm -rf {cache_dir}', shell=True)
        elif os.path.exists(cache_dir):
            logging.info(f"Nettoyage du cache: {cache_dir}")
            shutil.rmtree(cache_dir)

def sync_chromedriver_with_force():
    """Synchronise ChromeDriver en forçant l'utilisation du bon Chrome"""
    try:
        import undetected_chromedriver as uc
        
        # Détecter la version de Chrome
        major_version, full_version = get_chrome_version()
        
        # Trouver le bon binaire Chrome
        chrome_binary = force_chrome_binary_path()
        if not chrome_binary:
            raise Exception("Aucun binaire Chrome valide trouvé")
        
        # Nettoyer tous les caches
        clear_all_chrome_caches()
        
        # Options Chrome
        chrome_options = uc.ChromeOptions()
        chrome_options.add_argument("--headless")
        chrome_options.add_argument("--no-sandbox")
        chrome_options.add_argument("--disable-dev-shm-usage")
        chrome_options.add_argument("--disable-gpu")
        chrome_options.add_argument("--disable-extensions")
        chrome_options.add_argument("--disable-plugins")
        
        # FORCER l'utilisation du bon binaire Chrome
        chrome_options.binary_location = chrome_binary
        
        logging.info(f"Forçage Chrome binaire: {chrome_binary}")
        logging.info(f"Téléchargement ChromeDriver pour version {major_version}...")
        
        # Créer le driver avec le binaire forcé
        driver = uc.Chrome(
            options=chrome_options,
            version_main=major_version,
            driver_executable_path=None
        )
        
        # Test rapide
        logging.info("Test du ChromeDriver...")
        driver.get("about:blank")
        logging.info("✅ ChromeDriver synchronisé avec succès")
        
        driver.quit()
        return True
        
    except Exception as e:
        logging.error(f"Erreur lors de la synchronisation: {e}")
        return False

def test_final():
    """Test final avec configuration identique"""
    try:
        import undetected_chromedriver as uc
        
        chrome_binary = force_chrome_binary_path()
        
        chrome_options = uc.ChromeOptions()
        chrome_options.add_argument("--headless")
        chrome_options.add_argument("--no-sandbox")
        chrome_options.add_argument("--disable-dev-shm-usage")
        chrome_options.binary_location = chrome_binary
        
        driver = uc.Chrome(options=chrome_options, version_main=None)
        driver.get("about:blank")
        logging.info("✅ Test final réussi")
        driver.quit()
        return True
        
    except Exception as e:
        logging.error(f"Échec du test final: {e}")
        return False

if __name__ == "__main__":
    logging.info("=== Synchronisation ChromeDriver FORCÉE ===")
    
    if sync_chromedriver_with_force():
        if test_final():
            logging.info("🎉 Synchronisation forcée réussie")
            sys.exit(0)
        else:
            logging.error("❌ Échec du test final")
            sys.exit(1)
    else:
        logging.error("❌ Échec de la synchronisation forcée")
        sys.exit(1)
