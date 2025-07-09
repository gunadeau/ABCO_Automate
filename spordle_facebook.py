

import os
import sys
import time
import json
import requests
from datetime import datetime, date, timedelta
from pathlib import Path
from typing import List, Dict, Optional
import logging
from dataclasses import dataclass
from PIL import Image, ImageDraw
import io
import re
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException, NoSuchElementException
import undetected_chromedriver as uc

# Configuration du logging (compatible Windows)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('spordle_facebook.log', encoding='utf-8'),
        logging.StreamHandler(sys.stdout)
    ]
)

# Configuration pour Windows (encodage console)
if sys.platform.startswith('win'):
    import codecs
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')

# ============ CONFIGURATION DATE DE TEST ============
# Changez cette valeur pour tester différentes dates :
# 0 = aujourd'hui, 1 = demain, 2 = après-demain, etc.
JOURS_OFFSET = 0  # TESTEZ DEMAIN

# Ou décommentez pour une date spécifique :
# DATE_SPECIFIQUE = datetime(2025, 7, 12)  # Format: (année, mois, jour)
DATE_SPECIFIQUE = None
# ====================================================
logger = logging.getLogger(__name__)

@dataclass
class Match:
    """Représente un match de baseball"""
    date: str
    time: str
    home_team: str
    away_team: str
    venue: str
    full_text: str
    test_mode: bool = False

class SpordleConfig:
    """Configuration pour Spordle"""
    def __init__(self):
        self.login_url = "https://myaccount.spordle.com/login?c=play&identity=0c74c85b-ba18-41f7-b170-e7b0dd3f4719&r=https%3A%2F%2Fplay.spordle.com%2Flogin%3Fu%3Dgunadeau%40hotmail.com&link=1"
        self.password = os.getenv('SPORDLE_PASS')
        self.games_url = "https://play.spordle.com/games?filter=%7B%22_include%22%3A%5B%22gameBracket%22%5D%2C%22homeTeamOffices%22%3A%5B3784%5D%2C%22seasonId%22%3A%222025-26%22%7D&order=ASC&order=ASC&order=ASC&page=1&perPage=25&sort=date&sort=startTime&sort=number"
        
        if not self.password:
            raise ValueError("Variable d'environnement SPORDLE_PASS non définie")

class FacebookConfig:
    """Configuration pour Facebook"""
    def __init__(self):
        self.page_id = os.getenv('FACEBOOK_PAGE_ID')
        self.access_token = os.getenv('FACEBOOK_ACCESS_TOKEN')
        self.photo_api_url = f"https://graph.facebook.com/v22.0/{self.page_id}/photos"
        self.feed_api_url = f"https://graph.facebook.com/v22.0/{self.page_id}/feed"
        
        if not self.page_id or not self.access_token:
            raise ValueError("Variables d'environnement FACEBOOK_PAGE_ID ou FACEBOOK_ACCESS_TOKEN non définies")

class ImageProcessor:
    """Classe pour traiter les images des commanditaires"""
    
    @staticmethod
    def resize_image(source_path: str, destination_path: str, target_size: int = 1200, target_aspect_ratio: float = 1.0) -> bool:
        """
        Redimensionne une image et ajuste le ratio d'aspect
        """
        try:
            if not os.path.exists(source_path):
                logger.warning(f"Le fichier {source_path} n'existe pas")
                return False
            
            with Image.open(source_path) as img:
                original_width, original_height = img.size
                
                if original_width <= 0 or original_height <= 0:
                    logger.warning(f"Dimensions invalides pour {source_path}")
                    return False
                
                original_aspect_ratio = original_width / original_height
                logger.info(f"Image {source_path}: {original_width}x{original_height}, ratio={original_aspect_ratio:.2f}")
                
                # Calculer les nouvelles dimensions
                if original_aspect_ratio > target_aspect_ratio:
                    new_width = target_size
                    new_height = int(target_size / original_aspect_ratio)
                else:
                    new_height = target_size
                    new_width = int(target_size * original_aspect_ratio)
                
                new_width = max(1, new_width)
                new_height = max(1, new_height)
                
                # Redimensionner l'image
                resized_img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
                
                # Créer une image carrée avec fond blanc
                final_img = Image.new('RGB', (target_size, target_size), 'white')
                x_offset = (target_size - new_width) // 2
                y_offset = (target_size - new_height) // 2
                final_img.paste(resized_img, (x_offset, y_offset))
                
                # Sauvegarder
                final_img.save(destination_path, 'PNG', quality=95)
                
                file_size = os.path.getsize(destination_path)
                logger.info(f"Image sauvegardée: {destination_path} ({file_size/1024:.1f} KB)")
                
                return True
                
        except Exception as e:
            logger.error(f"Erreur lors du redimensionnement de {source_path}: {e}")
            return False

class SpordleScheduleExtractor:
    """Classe pour extraire les horaires de Spordle"""
    
    def __init__(self, config: SpordleConfig):
        self.config = config
        self.driver = None
        self.safety_mode = True
        self.date_validated = False
    
    def start_driver(self) -> bool:
        """Démarre le driver Chrome"""
        try:
            options = uc.ChromeOptions()
            options.add_argument('--disable-blink-features=AutomationControlled')
            options.add_argument('--no-sandbox')
            options.add_argument('--disable-dev-shm-usage')
            
            # Configuration pour GitHub Actions (environnement CI)
            if os.getenv('GITHUB_ACTIONS'):
                options.add_argument('--headless=new')
                options.add_argument('--disable-gpu')
                options.add_argument('--disable-web-security')
                options.add_argument('--allow-running-insecure-content')
                options.add_argument('--disable-extensions')
                options.add_argument('--window-size=1920,1080')
                logger.info("Mode GitHub Actions détecté - Chrome en mode headless")
            
            self.driver = uc.Chrome(options=options)
            logger.info("Driver Chrome démarré avec succès")
            return True
        except Exception as e:
            logger.error(f"Erreur lors du démarrage du driver: {e}")
            return False
    
    def login(self) -> bool:
        """Se connecte à Spordle"""
        try:
            logger.info("=== CONNEXION À SPORDLE ===")
            self.driver.get(self.config.login_url)
            logger.info(f"Page de connexion chargée: {self.config.login_url}")
            time.sleep(3)
            
            # Saisir le mot de passe
            password_field = self.driver.find_element(By.NAME, "password")
            password_field.send_keys(self.config.password)
            logger.info("Mot de passe saisi")
            
            password_field.submit()
            logger.info("Connexion envoyée")
            time.sleep(5)
            
            # Vérifier la connexion
            current_url = self.driver.current_url
            logger.info(f"URL après connexion: {current_url}")
            
            if "play.spordle.com" in current_url:
                logger.info("✅ Connexion à Spordle réussie!")
                return True
            else:
                logger.warning("❌ Connexion à Spordle échouée")
                return False
                
        except Exception as e:
            logger.error(f"Erreur lors de la connexion: {e}")
            return False
    
    def get_matches(self, test_date: Optional[datetime] = None) -> List[Match]:
        """
        Version BULLETPROOF de l'extraction des matchs avec paramètre de date pour tests
        """
        if test_date is None:
            test_date = datetime.now()
        
        # Variables de contrôle strictes
        self.safety_mode = True
        self.date_validated = False
        matches_today = []
        all_date_elements = []  # Initialiser ici pour éviter l'erreur
        
        try:
            logger.info("Navigation vers la page des matchs...")
            self.driver.get(self.config.games_url)
            time.sleep(7)
            
            logger.info("Recherche des matchs du jour...")
            
            # Formater la date à rechercher (avec et sans zéro initial)
            today_formatted = test_date.strftime("%A, %B %d, %Y")  # "Wednesday, July 09, 2025"
            today_formatted2 = test_date.strftime("%A, %B %-d, %Y") if sys.platform != 'win32' else test_date.strftime("%A, %B %#d, %Y")  # "Wednesday, July 9, 2025"
            
            if test_date.date() != date.today():
                logger.info(f"MODE TEST - Recherche des matchs pour : {test_date.strftime('%Y-%m-%d')}")
            
            logger.info(f"DEBUG: Date recherchée : '{today_formatted}' ou '{today_formatted2}'")
            logger.info(f"DEBUG: SAFETY_MODE = {self.safety_mode}")
            
            time.sleep(3)
            
            # ÉTAPE 1 : VÉRIFICATION HTML BRUT
            logger.info("DEBUG: === ÉTAPE 1 : VÉRIFICATION HTML BRUT ===")
            page_source = self.driver.page_source
            
            # Debug: Afficher des extraits de HTML qui contiennent des dates
            import re
            date_patterns = re.findall(r'\w+day,\s+\w+\s+\d{1,2},\s+\d{4}', page_source)
            logger.info(f"DEBUG: Dates trouvées dans le HTML : {date_patterns}")
            
            # Chercher également des formats de date alternatifs
            alt_date_patterns = re.findall(r'July\s+\d{1,2},?\s+2025|2025-\d{2}-\d{2}|\d{1,2}/\d{1,2}/2025', page_source)
            logger.info(f"DEBUG: Dates alternatives trouvées : {alt_date_patterns}")
            
            date_in_html = today_formatted in page_source or today_formatted2 in page_source
            
            if date_in_html:
                logger.info("DEBUG: Date d'aujourd'hui trouvée dans le HTML brut")
            else:
                logger.info("DEBUG: Date d'aujourd'hui NON trouvée dans le HTML brut")
            
            # ÉTAPE 2 : VALIDATION DE SÉCURITÉ
            logger.info("DEBUG: === ÉTAPE 2 : VALIDATION DE SÉCURITÉ ===")
            if not date_in_html:
                logger.warning("Date d'aujourd'hui absente du HTML - SAFETY_MODE MAINTENU")
                self.safety_mode = True
                self.date_validated = False
            else:
                logger.info("DEBUG: Date trouvée dans HTML - Validation DOM en cours...")
                
                # ÉTAPE 3 : VÉRIFICATION DOM
                logger.info("DEBUG: === ÉTAPE 3 : VÉRIFICATION DOM ===")
                date_selector_patterns = [
                    "//h6[contains(@class, 'MuiTypography-subtitle2') and contains(@class, 'MuiTypography-displayInline')]",
                    "//h6[contains(@class, 'MuiTypography-root') and contains(text(), '2025')]"
                ]
                
                today_date_found = False
                for pattern in date_selector_patterns:
                    try:
                        elements = self.driver.find_elements(By.XPATH, pattern)
                        for el in elements:
                            text = el.text.strip()
                            if re.match(r'\w+day,.*\d{4}', text) and len(text) < 100:
                                all_date_elements.append({
                                    'element': el,
                                    'text': text
                                })
                                logger.info(f"DEBUG: Élément de date DOM trouvé : '{text}'")
                                
                                # Vérifier si c'est la date d'aujourd'hui
                                if text == today_formatted or text == today_formatted2:
                                    today_date_found = True
                                    logger.info(f"DEBUG: DATE D'AUJOURD'HUI CONFIRMÉE DOM : '{text}'")
                    except Exception as e:
                        logger.info(f"DEBUG: Erreur avec pattern '{pattern}': {e}")
                
                # VALIDATION FINALE
                if today_date_found:
                    self.safety_mode = False
                    self.date_validated = True
                    logger.info("DEBUG: VALIDATION COMPLÈTE - SAFETY_MODE DÉSACTIVÉ")
                else:
                    self.safety_mode = True
                    self.date_validated = False
                    logger.info("DEBUG: Date HTML trouvée mais PAS dans DOM - SAFETY_MODE MAINTENU")
            
            logger.info("DEBUG: === RÉSULTAT VALIDATION ===")
            logger.info(f"DEBUG: SAFETY_MODE = {self.safety_mode}")
            logger.info(f"DEBUG: DATE_VALIDATED = {self.date_validated}")
            
            # ÉTAPE 4 : DÉCISION EXTRACTION
            logger.info("DEBUG: === ÉTAPE 4 : DÉCISION EXTRACTION ===")
            if self.safety_mode:
                logger.warning("SAFETY_MODE ACTIVÉ - AUCUNE EXTRACTION DE MATCHS")
                logger.info("DEBUG: Raison : Date d'aujourd'hui non validée")
                
                # Diagnostic des dates disponibles
                logger.info("=== DATES DISPONIBLES ===")
                for date_info in all_date_elements:
                    logger.info(f"Date disponible : '{date_info['text']}'")
                
                # Sauvegarde debug
                temp_folder = Path("temp")
                temp_folder.mkdir(exist_ok=True)
                debug_file = temp_folder / "spordle_games_debug.html"
                with open(debug_file, 'w', encoding='utf-8') as f:
                    f.write(page_source)
                logger.info(f"HTML sauvegardé : {debug_file}")
                
            else:
                logger.info("DEBUG: SAFETY_MODE DÉSACTIVÉ - EXTRACTION AUTORISÉE")
                logger.info("DEBUG: Recherche du tableau de matchs...")
                
                # EXTRACTION RÉELLE DES MATCHS
                matches_today = self._extract_matches_from_dom(all_date_elements, today_formatted, today_formatted2, test_date)
        
        except Exception as e:
            logger.error(f"Erreur CRITIQUE : {e}")
            self.safety_mode = True
            self.date_validated = False
            matches_today = []
        
        # ÉTAPE 5 : RETOUR SÉCURISÉ
        logger.info("DEBUG: === ÉTAPE 5 : RETOUR SÉCURISÉ ===")
        logger.info(f"DEBUG: SAFETY_MODE final = {self.safety_mode}")
        logger.info(f"DEBUG: DATE_VALIDATED final = {self.date_validated}")
        logger.info(f"DEBUG: matches_today count = {len(matches_today)}")
        
        # VÉRIFICATION FINALE ABSOLUE
        if self.safety_mode:
            logger.info("DEBUG: SAFETY_MODE - Retour tableau vide garanti")
            matches_today = []
        
        if matches_today and not self.date_validated:
            logger.warning("INCOHÉRENCE DÉTECTÉE : Matchs trouvés sans validation de date !")
            logger.warning("CORRECTION FORCÉE : Tableau vidé")
            matches_today = []
        
        logger.info(f"DEBUG: Nombre de matchs retournés : {len(matches_today)}")
        return matches_today
    
    def _extract_matches_from_dom(self, all_date_elements: List[Dict], today_formatted: str, today_formatted2: str, test_date: datetime) -> List[Match]:
        """Extrait les matchs du DOM"""
        matches = []
        
        try:
            # Trouver l'élément de date d'aujourd'hui
            today_date_element = None
            for date_info in all_date_elements:
                if date_info['text'] == today_formatted or date_info['text'] == today_formatted2:
                    today_date_element = date_info['element']
                    break
            
            if not today_date_element:
                logger.warning("❌ Impossible de retrouver l'élément de date")
                return matches
            
            # Trouver le tableau associé
            table_element = None
            table_search_patterns = [
                "./following-sibling::table[contains(@class, 'MuiTable-root')][1]",
                "./following::table[contains(@class, 'MuiTable-root')][1]",
                "./..//table[contains(@class, 'MuiTable-root')][1]",
                "./ancestor::div[1]//table[contains(@class, 'MuiTable-root')][1]"
            ]
            
            for table_pattern in table_search_patterns:
                try:
                    table_element = today_date_element.find_element(By.XPATH, table_pattern)
                    if table_element:
                        logger.info(f"DEBUG: ✅ Tableau trouvé avec pattern : '{table_pattern}'")
                        break
                except:
                    # Pattern ne fonctionne pas, essayer le suivant
                    pass
            
            if not table_element:
                logger.warning("❌ Aucun tableau trouvé pour la date d'aujourd'hui")
                return matches
            
            # Extraire les matchs du tableau
            table_rows = table_element.find_elements(By.XPATH, ".//tr[contains(@class, 'MuiTableRow-root')]")
            logger.info(f"DEBUG: Nombre de lignes dans le tableau : {len(table_rows)}")
            
            for row in table_rows:
                try:
                    # Extraire l'heure
                    time_cells = row.find_elements(By.XPATH, ".//td[contains(@class, 'column-time')]//span[contains(@class, 'MuiTypography-noWrap')]")
                    if not time_cells:
                        continue
                    
                    time_text = time_cells[0].text.strip()
                    start_time = time_text
                    time_match = re.match(r'^(\d{1,2}:\d{2})', time_text)
                    if time_match:
                        start_time = time_match.group(1)
                    
                    # Extraire les équipes
                    team_elements = row.find_elements(By.XPATH, ".//td[contains(@class, 'column-homeTeamId')]//p[contains(@class, 'MuiTypography-displayInline')]")
                    teams = []
                    for team_el in team_elements:
                        team_text = team_el.text.strip()
                        if (re.match(r'TITANS|[A-Z]+.*\d+.*[A-Z]', team_text) and 
                            not re.match(r'^Game|^Parc|^Terrain', team_text)):
                            teams.append(team_text)
                    
                    # Extraire le lieu
                    venue_elements = row.find_elements(By.XPATH, ".//td[contains(@class, 'column-arenaId')]//p[contains(@class, 'MuiTypography-displayInline')][1]")
                    venue = venue_elements[0].text.strip() if venue_elements else ""
                    
                    # Créer l'objet match
                    match_info = Match(
                        date=today_formatted,
                        time=start_time,
                        home_team="",
                        away_team="",
                        venue=venue,
                        full_text=time_text,
                        test_mode=(test_date.date() != date.today())
                    )
                    
                    # Assigner les équipes
                    if len(teams) >= 2:
                        match_info.home_team = teams[0]
                        match_info.away_team = teams[1]
                    elif len(teams) == 1:
                        match_info.home_team = teams[0]
                    
                    # Simplifier les noms d'équipes
                    match_info.home_team = self._simplify_team_name(match_info.home_team)
                    match_info.away_team = self._simplify_team_name(match_info.away_team)
                    
                    # Ajouter le match s'il a une heure valide
                    if match_info.time:
                        matches.append(match_info)
                        logger.info(f"DEBUG: ✅ Match ajouté : '{match_info.home_team}' vs '{match_info.away_team}' à '{match_info.time}'")
                
                except Exception as e:
                    logger.warning(f"Erreur lors de l'analyse d'une ligne : {e}")
        
        except Exception as e:
            logger.warning(f"Erreur lors de l'extraction des matchs : {e}")
        
        return matches
    
    def _simplify_team_name(self, team_name: str) -> str:
        """Simplifie le nom d'une équipe"""
        if not team_name:
            return team_name
        
        # Pattern pour "TOROS 3 - 9U - B - Masculin - LOTBINIÈRE" -> "TOROS 3 9UB"
        match = re.match(r'^([A-Z]+(?:\s+\d+)?).*?(\d+U).*?([AB])', team_name)
        if match:
            team_name_part = match.group(1).strip()
            age_group = match.group(2)
            division = match.group(3)
            simplified = f"{team_name_part} {age_group}{division}"
            logger.info(f"DEBUG: Nom d'équipe simplifié : '{simplified}'")
            return simplified
        
        return team_name
    
    def close(self):
        """Ferme le driver"""
        if self.driver:
            self.driver.quit()
            logger.info("Driver fermé")

class FacebookPublisher:
    """Classe pour publier sur Facebook"""
    
    def __init__(self, config: FacebookConfig):
        self.config = config
    
    def publish_matches(self, matches: List[Match], test_date: datetime) -> bool:
        """Publie les matchs sur Facebook"""
        try:
            # Construire le message
            message = self._build_message(matches, test_date)
            
            logger.info("=== PUBLICATION FACEBOOK ===")
            logger.info("Message qui sera publié :")
            logger.info("=" * 50)
            logger.info(message)
            logger.info("=" * 50)
            
            # Publier le message texte avec form-data (plus compatible avec les émojis)
            feed_data = {
                'message': message.encode('utf-8').decode('utf-8'),
                'access_token': self.config.access_token,
                'published': 'true'
            }
            
            response = requests.post(
                self.config.feed_api_url,
                data=feed_data
            )
            
            # Debug: afficher la réponse en cas d'erreur
            if response.status_code != 200:
                logger.error(f"Réponse Facebook: {response.status_code} - {response.text}")
            
            response.raise_for_status()
            
            post_data = response.json()
            post_id = post_data['id']
            logger.info(f"✅ Publication Facebook réussie. Post ID : {post_id}")
            
            # Attacher les images si disponibles
            self._attach_sponsor_images(post_id)
            
            logger.info("✅ Publication complète réussie !")
            return True
            
        except Exception as e:
            logger.error(f"Erreur lors de la publication Facebook : {e}")
            return False
    
    def _build_message(self, matches: List[Match], test_date: datetime) -> str:
        """Construit le message Facebook"""
        current_date = test_date.strftime("%Y-%m-%d")
        intro_message = "Venez encourager nos Titans ! Voici les matchs de la journée sur nos terrains:\n\n"
        table_header = f"⚾ Matchs de la journée ({current_date}) ⚾\n\n"
        table_content = ""
        
        for match in matches:
            venue = re.sub(r" - Baseball.*$", "", match.venue)
            table_content += f"⏰ {match.time}  {match.home_team}  vs  {match.away_team}  🏟️ {venue}\n"
        
        automated_message = "*** Ceci est un message automatisé, toujours valider l'horaire sur: https://page.spordle.com/fr/ligue-de-baseball-mineur-de-la-region-de-quebec/schedule-stats-standings ***"
        
        return f"{intro_message}{table_header}{table_content}\n{automated_message}\n\nMerci à nos commanditaires !"
    
    def _attach_sponsor_images(self, post_id: str):
        """Attache les images des commanditaires"""
        try:
            # Créer le dossier temporaire
            temp_folder = Path("temp")
            temp_folder.mkdir(exist_ok=True)
            
            # Récupérer les images des commanditaires
            sponsor_folder = Path("Commanditaire")
            if not sponsor_folder.exists():
                logger.warning("Dossier 'commanditaire' non trouvé")
                return
            
            image_files = [f for f in sponsor_folder.iterdir() 
                          if f.is_file() and f.suffix.lower() in ['.jpg', '.jpeg', '.png']]
            
            logger.info(f"Fichiers de commanditaires trouvés : {len(image_files)}")
            
            if not image_files:
                return
            
            # Redimensionner les images
            resized_image_paths = []
            for image_file in image_files:
                temp_image_path = temp_folder / f"resized_{image_file.stem}.png"
                success = ImageProcessor.resize_image(
                    str(image_file), 
                    str(temp_image_path), 
                    target_size=1200, 
                    target_aspect_ratio=1.0
                )
                if success:
                    resized_image_paths.append(str(temp_image_path))
            
            if not resized_image_paths:
                return
            
            # Publier les images et les attacher
            attached_media = []
            for image_path in resized_image_paths:
                try:
                    with open(image_path, 'rb') as img_file:
                        files = {'source': img_file}
                        data = {
                            'access_token': self.config.access_token,
                            'published': 'false'
                        }
                        
                        response = requests.post(self.config.photo_api_url, files=files, data=data)
                        response.raise_for_status()
                        
                        photo_data = response.json()
                        attached_media.append({'media_fbid': photo_data['id']})
                        
                except Exception as e:
                    logger.warning(f"Erreur lors de l'upload de {image_path}: {e}")
            
            # Attacher les images au post
            if attached_media:
                update_url = f"https://graph.facebook.com/v22.0/{post_id}"
                update_data = {
                    'attached_media': attached_media,
                    'access_token': self.config.access_token
                }
                
                response = requests.post(update_url, json=update_data)
                response.raise_for_status()
                
                logger.info(f"✅ {len(attached_media)} images attachées avec succès")
            
            # Nettoyer les fichiers temporaires
            for image_path in resized_image_paths:
                try:
                    os.remove(image_path)
                except:
                    pass
                    
        except Exception as e:
            logger.error(f"Erreur lors de l'attachement des images : {e}")

def main():
    """Fonction principale"""
    try:
        # Configuration
        spordle_config = SpordleConfig()
        facebook_config = FacebookConfig()
        
        # Configuration de la date via variable d'environnement (pour GitHub Actions)
        date_offset = int(os.getenv('DATE_OFFSET', '0'))
        test_date = datetime.now() + timedelta(days=date_offset)
        
        if date_offset != 0:
            logger.info(f"Mode test: Date décalée de {date_offset} jour(s) - {test_date.strftime('%Y-%m-%d')}")
        
        # Extraction des matchs
        extractor = SpordleScheduleExtractor(spordle_config)
        
        try:
            if not extractor.start_driver():
                logger.error("Impossible de démarrer le driver")
                return False
            
            if not extractor.login():
                logger.error("Connexion à Spordle échouée")
                return False
            
            # Récupérer les matchs
            matches = extractor.get_matches(test_date)
            
            # Vérification cruciale
            if not matches:
                logger.info("")
                logger.info("❌ AUCUNE PUBLICATION FACEBOOK EFFECTUÉE")
                logger.info("━" * 50)
                logger.info(f"ℹ️ Aucun match trouvé pour la date testée ({test_date.strftime('%A, %B %d, %Y')})")
                logger.info("")
                logger.info("🔍 Raisons possibles :")
                logger.info("   • Aucun match programmé pour cette date")
                logger.info("   • La date dans Spordle ne correspond pas au format attendu")
                logger.info("   • Problème de connexion ou de chargement de la page")
                logger.info("   • Structure de la page Spordle modifiée")
                logger.info("")
                logger.info("📋 Actions recommandées :")
                logger.info("   • Vérifier manuellement s'il y a des matchs sur Spordle pour cette date")
                logger.info("   • Consulter le fichier de debug généré : temp/spordle_games_debug.html")
                logger.info("   • Réessayer plus tard si c'est un problème temporaire")
                logger.info("━" * 50)
                return False
            
            logger.info(f"✅ {len(matches)} match(s) trouvé(s) pour aujourd'hui")
            
            # Publication sur Facebook
            publisher = FacebookPublisher(facebook_config)
            return publisher.publish_matches(matches, test_date)
            
        finally:
            extractor.close()
            
    except Exception as e:
        logger.error(f"Erreur dans la fonction principale : {e}")
        return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
