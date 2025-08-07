#!/usr/bin/env python3
"""
Script pour synchroniser automatiquement ChromeDriver avec la version de Chrome installée
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

def clear_chromedriver_cache():
    """Nettoie le cache d'undetected_chromedriver"""
    cache_dir = os.path.expanduser('~/.local/share/undetected_chromedriver')
    if os.path.exists(cache_dir):
        logging.info("Nettoyage du cache ChromeDriver...")
        shutil.rmtree(cache_dir)
        logging.info("Cache nettoyé")
    else:
        logging.info("Aucun cache ChromeDriver trouvé")

def sync_chromedriver():
    """Synchronise ChromeDriver avec la version de Chrome installée"""
    try:
        # Importer undetected_chromedriver
        import undetected_chromedriver as uc
        
        # Détecter la version de Chrome
        major_version, full_version = get_chrome_version()
        
        # Nettoyer le cache pour forcer le téléchargement
        clear_chromedriver_cache()
        
        # Options Chrome pour le test
        chrome_options = uc.ChromeOptions()
        chrome_options.add_argument("--headless")
        chrome_options.add_argument("--no-sandbox")
        chrome_options.add_argument("--disable-dev-shm-usage")
        chrome_options.add_argument("--disable-gpu")
        
        # Forcer le téléchargement du ChromeDriver correspondant
        logging.info(f"Téléchargement du ChromeDriver pour Chrome version {major_version}...")
        driver = uc.Chrome(
            options=chrome_options,
            version_main=major_version,
            driver_executable_path=None
        )
        
        # Test rapide
        logging.info("Test du ChromeDriver...")
        driver.get("about:blank")
        logging.info("✅ ChromeDriver téléchargé et testé avec succès")
        
        driver.quit()
        return True
        
    except Exception as e:
        logging.error(f"Erreur lors de la synchronisation: {e}")
        return False

def test_chromedriver():
    """Test final du ChromeDriver"""
    try:
        import undetected_chromedriver as uc
        
        chrome_options = uc.ChromeOptions()
        chrome_options.add_argument("--headless")
        chrome_options.add_argument("--no-sandbox")
        chrome_options.add_argument("--disable-dev-shm-usage")
        
        driver = uc.Chrome(options=chrome_options, version_main=None)
        driver.get("about:blank")
        logging.info("✅ Test final réussi - ChromeDriver prêt à l'emploi")
        driver.quit()
        return True
        
    except Exception as e:
        logging.error(f"Échec du test final: {e}")
        return False

if __name__ == "__main__":
    logging.info("=== Synchronisation ChromeDriver ===")
    
    # Synchroniser ChromeDriver
    if sync_chromedriver():
        # Test final
        if test_chromedriver():
            logging.info("🎉 Synchronisation terminée avec succès")
            sys.exit(0)
        else:
            logging.error("❌ Échec du test final")
            sys.exit(1)
    else:
        logging.error("❌ Échec de la synchronisation")
        sys.exit(1)
