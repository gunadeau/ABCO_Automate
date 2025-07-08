# Paramètres Spordle
$loginname = "gunadeau@hotmail.com"
$loginUrl = "https://play.spordle.com/login"
$pass = $env:SPORDLE_PASS  # Remplacez par votre mot de passe
$gamesUrl = "https://play.spordle.com/games?filter=%7B%22_include%22%3A%5B%22gameBracket%22%5D%2C%22homeTeamOffices%22%3A%5B3784%5D%2C%22seasonId%22%3A%222025-26%22%7D&order=ASC&order=ASC&order=ASC&page=1&perPage=25&sort=date&sort=startTime&sort=number"
$testDate = Get-Date  # "2025-06-07"

# Paramètres Facebook
$scriptDir = $PSScriptRoot
$commanditaireFolder = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "commanditaire"))
$tempFolder = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "temp"))
$pageId = $env:FACEBOOK_PAGE_ID
$accessToken = $env:FACEBOOK_ACCESS_TOKEN
$photoApiUrl = "https://graph.facebook.com/v22.0/$pageId/photos"
$feedApiUrl = "https://graph.facebook.com/v22.0/$pageId/feed"

# Charger le module Selenium
Import-Module Selenium

# Créer un dossier temporaire pour les images redimensionnées s'il n'existe pas
if (-not (Test-Path $tempFolder)) {
    New-Item -Path $tempFolder -ItemType Directory | Out-Null
}

# Charger l'assemblage System.Drawing pour redimensionner les images
Add-Type -AssemblyName System.Drawing

# Fonction pour redimensionner une image et ajuster le ratio d'aspect
function Resize-Image {
    param (
        [string]$SourcePath,
        [string]$DestinationPath,
        [int]$TargetSize = 1200,
        [float]$TargetAspectRatio = 1.0
    )

    try {
        if (-not (Test-Path $SourcePath)) {
            Write-Warning "Le fichier $SourcePath n'existe pas ou n'est pas accessible."
            return $false
        }

        $image = [System.Drawing.Image]::FromFile($SourcePath)
        $originalWidth = $image.Width
        $originalHeight = $image.Height

        if ($originalWidth -le 0 -or $originalHeight -le 0) {
            Write-Warning "Dimensions invalides pour l'image $SourcePath : Largeur=$originalWidth, Hauteur=$originalHeight"
            $image.Dispose()
            return $false
        }

        $originalAspectRatio = $originalWidth / $originalHeight
        Write-Host "Image $SourcePath : Largeur=$originalWidth, Hauteur=$originalHeight, Ratio=$originalAspectRatio"

        if ($originalWidth -lt $TargetSize -or $originalHeight -lt $TargetSize) {
            Write-Warning "L'image originale $SourcePath est plus petite que la taille cible ($TargetSize x $TargetSize). Cela peut entraîner une perte de qualité (upscaling)."
        }

        if ($originalAspectRatio -gt $TargetAspectRatio) {
            $newWidth = $TargetSize
            $newHeight = [math]::Round($TargetSize / $originalAspectRatio)
        } else {
            $newHeight = $TargetSize
            $newWidth = [math]::Round($TargetSize * $originalAspectRatio)
        }

        $newWidth = [math]::Max(1, $newWidth)
        $newHeight = [math]::Max(1, $newHeight)
        Write-Host "Nouvelles dimensions pour $SourcePath : Largeur=$newWidth, Hauteur=$newHeight"

        $tempImage = New-Object System.Drawing.Bitmap $newWidth, $newHeight
        $graphics = [System.Drawing.Graphics]::FromImage($tempImage)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.DrawImage($image, 0, 0, $newWidth, $newHeight)

        $finalImage = New-Object System.Drawing.Bitmap $TargetSize, $TargetSize
        $finalGraphics = [System.Drawing.Graphics]::FromImage($finalImage)
        $finalGraphics.Clear([System.Drawing.Color]::White)
        $xOffset = [math]::Round(($TargetSize - $newWidth) / 2)
        $yOffset = [math]::Round(($TargetSize - $newHeight) / 2)
        $finalGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $finalGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $finalGraphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $finalGraphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $finalGraphics.DrawImage($tempImage, $xOffset, $yOffset, $newWidth, $newHeight)

        $finalImage.Save($DestinationPath, [System.Drawing.Imaging.ImageFormat]::Png)

        $fileInfo = Get-Item $DestinationPath
        Write-Host "Image redimensionnée sauvegardée : $DestinationPath (Taille : $($fileInfo.Length / 1KB) KB)"

        $finalGraphics.Dispose()
        $finalImage.Dispose()
        $graphics.Dispose()
        $tempImage.Dispose()
        $image.Dispose()
        return $true
    }
    catch {
        Write-Error "Erreur lors du redimensionnement de l'image $SourcePath : $_"
        if ($image) { $image.Dispose() }
        return $false
    }
}

# Version BULLETPROOF de Get-SpordleMatches avec paramètre de date pour tests
function Get-SpordleMatches {
    param(
        $driver,
        [DateTime]$TestDate = (Get-Date)  # Paramètre optionnel avec date du jour par défaut
    )
    
    # VARIABLES DE CONTRÔLE STRICTES
    $SAFETY_MODE = $true  # Mode sécurité activé par défaut
    $DATE_VALIDATED = $false  # Date validée
    $matchesToday = @()
    
    try {
        Write-Host "Navigation vers la page des matchs..."
        $driver.Navigate().GoToUrl($gamesUrl)
        Start-Sleep -Seconds 7
        
        Write-Host "Recherche des matchs du jour..."
        
        # Obtenir la date à rechercher (paramètre ou date du jour)
        $currentDate = $TestDate
        $todayFormatted = $currentDate.ToString("dddd, MMMM d, yyyy", [System.Globalization.CultureInfo]::InvariantCulture)
        $todayFormatted2 = $currentDate.ToString("dddd, MMMM dd, yyyy", [System.Globalization.CultureInfo]::InvariantCulture)
        
        # Affichage spécial si on teste une autre date
        if ($TestDate.Date -ne (Get-Date).Date) {
            Write-Host "🧪 MODE TEST - Recherche des matchs pour : $($TestDate.ToString('yyyy-MM-dd'))" -ForegroundColor Yellow
        }
        
        Write-Host "DEBUG: Date recherchée : '$todayFormatted' ou '$todayFormatted2'"
        Write-Host "DEBUG: SAFETY_MODE = $SAFETY_MODE"
        
        # Attendre que la page soit complètement chargée
        Start-Sleep -Seconds 3
        
        # ÉTAPE 1 : VÉRIFICATION HTML BRUT
        Write-Host "DEBUG: === ÉTAPE 1 : VÉRIFICATION HTML BRUT ==="
        $pageSource = $driver.PageSource
        $dateInHtml = $false
        
        if ($pageSource -like "*$todayFormatted*" -or $pageSource -like "*$todayFormatted2*") {
            $dateInHtml = $true
            Write-Host "DEBUG: ✅ Date d'aujourd'hui trouvée dans le HTML brut"
        } else {
            Write-Host "DEBUG: ❌ Date d'aujourd'hui NON trouvée dans le HTML brut"
        }
        
        # ÉTAPE 2 : VALIDATION DE SÉCURITÉ
        Write-Host "DEBUG: === ÉTAPE 2 : VALIDATION DE SÉCURITÉ ==="
        if (-not $dateInHtml) {
            Write-Warning "❌ Date d'aujourd'hui absente du HTML - SAFETY_MODE MAINTENU"
            $SAFETY_MODE = $true
            $DATE_VALIDATED = $false
            Write-Host "DEBUG: SAFETY_MODE = $SAFETY_MODE, DATE_VALIDATED = $DATE_VALIDATED"
        } else {
            Write-Host "DEBUG: Date trouvée dans HTML - Validation DOM en cours..."
            
            # ÉTAPE 3 : VÉRIFICATION DOM
            Write-Host "DEBUG: === ÉTAPE 3 : VÉRIFICATION DOM ==="
            $allDateElements = @()
            $dateSelectorPatterns = @(
                "//h6[contains(@class, 'MuiTypography-subtitle2') and contains(@class, 'MuiTypography-displayInline')]",
                "//h6[contains(@class, 'MuiTypography-root') and contains(text(), '2025')]"
            )
            
            $todayDateFound = $false
            foreach ($pattern in $dateSelectorPatterns) {
                try {
                    $elements = $driver.FindElementsByXPath($pattern)
                    foreach ($el in $elements) {
                        $text = $el.Text.Trim()
                        if ($text -match '\w+day,.*\d{4}' -and $text.Length -lt 100) {
                            $allDateElements += @{
                                Element = $el
                                Text = $text
                            }
                            Write-Host "DEBUG: Élément de date DOM trouvé : '$text'"
                            
                            # Vérifier si c'est la date d'aujourd'hui
                            if ($text -eq $todayFormatted -or $text -eq $todayFormatted2) {
                                $todayDateFound = $true
                                Write-Host "DEBUG: ✅✅✅ DATE D'AUJOURD'HUI CONFIRMÉE DOM : '$text'"
                            }
                        }
                    }
                } catch {
                    Write-Host "DEBUG: Erreur avec pattern '$pattern': $_"
                }
            }
            
            # VALIDATION FINALE
            if ($todayDateFound) {
                $SAFETY_MODE = $false
                $DATE_VALIDATED = $true
                Write-Host "DEBUG: ✅ VALIDATION COMPLÈTE - SAFETY_MODE DÉSACTIVÉ"
            } else {
                $SAFETY_MODE = $true
                $DATE_VALIDATED = $false
                Write-Host "DEBUG: ❌ Date HTML trouvée mais PAS dans DOM - SAFETY_MODE MAINTENU"
            }
        }
        
        Write-Host "DEBUG: === RÉSULTAT VALIDATION ==="
        Write-Host "DEBUG: SAFETY_MODE = $SAFETY_MODE"
        Write-Host "DEBUG: DATE_VALIDATED = $DATE_VALIDATED"
        
        # ÉTAPE 4 : DÉCISION EXTRACTION
        Write-Host "DEBUG: === ÉTAPE 4 : DÉCISION EXTRACTION ==="
        if ($SAFETY_MODE -eq $true) {
            Write-Warning "🚨 SAFETY_MODE ACTIVÉ - AUCUNE EXTRACTION DE MATCHS"
            Write-Host "DEBUG: Raison : Date d'aujourd'hui non validée"
            
            # Diagnostic des dates disponibles
            Write-Host "=== DATES DISPONIBLES ==="
            foreach ($dateInfo in $allDateElements) {
                Write-Host "Date disponible : '$($dateInfo.Text)'"
            }
            
            # SAUVEGARDE DEBUG
            $debugFile = Join-Path $tempFolder "spordle_games_debug.html"
            $pageSource | Out-File -FilePath $debugFile -Encoding UTF8
            Write-Host "HTML sauvegardé : $debugFile"
            
        } else {
            Write-Host "DEBUG: ✅ SAFETY_MODE DÉSACTIVÉ - EXTRACTION AUTORISÉE"
            Write-Host "DEBUG: Recherche du tableau de matchs..."
            
            # EXTRACTION RÉELLE DES MATCHS
            try {
                # Trouver l'élément de date d'aujourd'hui
                $todayDateElement = $null
                foreach ($dateInfo in $allDateElements) {
                    if ($dateInfo.Text -eq $todayFormatted -or $dateInfo.Text -eq $todayFormatted2) {
                        $todayDateElement = $dateInfo.Element
                        break
                    }
                }
                
                if ($todayDateElement) {
                    # Trouver le tableau associé
                    $tableElement = $null
                    $tableSearchPatterns = @(
                        "./following-sibling::table[contains(@class, 'MuiTable-root')][1]",
                        "./following::table[contains(@class, 'MuiTable-root')][1]",
                        "./..//table[contains(@class, 'MuiTable-root')][1]",
                        "./ancestor::div[1]//table[contains(@class, 'MuiTable-root')][1]"
                    )
                    
                    foreach ($tablePattern in $tableSearchPatterns) {
                        try {
                            $tableElement = $todayDateElement.FindElementByXPath($tablePattern)
                            if ($tableElement) {
                                Write-Host "DEBUG: ✅ Tableau trouvé avec pattern : '$tablePattern'"
                                break
                            }
                        } catch {
                            # Pattern ne fonctionne pas, essayer le suivant
                        }
                    }
                    
                    if ($tableElement) {
                        # Extraire les matchs du tableau
                        $tableRows = $tableElement.FindElementsByXPath(".//tr[contains(@class, 'MuiTableRow-root')]")
                        Write-Host "DEBUG: Nombre de lignes dans le tableau : $($tableRows.Count)"
                        
                        foreach ($row in $tableRows) {
                            try {
                                # Extraire l'heure
                                $timeCell = $row.FindElementByXPath(".//td[contains(@class, 'column-time')]//span[contains(@class, 'MuiTypography-noWrap')]")
                                if (-not $timeCell) { continue }
                                
                                $timeText = $timeCell.Text.Trim()
                                $startTime = $timeText
                                if ($timeText -match '^(\d{1,2}:\d{2})') {
                                    $startTime = $matches[1]
                                }
                                
                                # Extraire les équipes
                                $teamElements = $row.FindElementsByXPath(".//td[contains(@class, 'column-homeTeamId')]//p[contains(@class, 'MuiTypography-displayInline')]")
                                $teams = @()
                                foreach ($teamEl in $teamElements) {
                                    $teamText = $teamEl.Text.Trim()
                                    if ($teamText -match 'TITANS|[A-Z]+.*\d+.*[A-Z]' -and $teamText -notmatch '^Game|^Parc|^Terrain') {
                                        $teams += $teamText
                                    }
                                }
                                
                                # Extraire le lieu
                                $venueElement = $row.FindElementByXPath(".//td[contains(@class, 'column-arenaId')]//p[contains(@class, 'MuiTypography-displayInline')][1]")
                                $venue = ""
                                if ($venueElement) {
                                    $venue = $venueElement.Text.Trim()
                                }
                                
                                # Créer l'objet match
                                $matchInfo = [PSCustomObject]@{
                                    Date = $todayFormatted
                                    Time = $startTime
                                    HomeTeam = ""
                                    AwayTeam = ""
                                    Venue = $venue
                                    FullText = $timeText
                                    TestMode = ($TestDate.Date -ne (Get-Date).Date)  # Indique si c'est un test
                                }
                                
                                # Assigner les équipes
                                if ($teams.Count -ge 2) {
                                    $matchInfo.HomeTeam = $teams[0]
                                    $matchInfo.AwayTeam = $teams[1]
                                } elseif ($teams.Count -eq 1) {
                                    $matchInfo.HomeTeam = $teams[0]
                                }
                                
                                # Simplifier les noms d'équipes pour un format plus compact
                                if (-not [string]::IsNullOrEmpty($matchInfo.HomeTeam)) {
                                    # Pattern pour différents formats :
                                    # "TOROS 3 - 9U - B - Masculin - LOTBINIÈRE" -> "TOROS 3 9UB"
                                    # "JAYS - 13U - A - MASCULIN - SUD DE LA BEAUCE" -> "JAYS 13UA"
                                    if ($matchInfo.HomeTeam -match '^([A-Z]+(?:\s+\d+)?).*?(\d+U).*?([AB])') {
                                        $teamName = $matches[1].Trim()  # "TOROS 3" ou "JAYS"
                                        $ageGroup = $matches[2]         # "9U" ou "13U"
                                        $division = $matches[3]         # "B" ou "A"
                                        $matchInfo.HomeTeam = "$teamName $ageGroup$division"  # "TOROS 3 9UB" ou "JAYS 13UA"
                                    }
                                    Write-Host "DEBUG: HomeTeam simplifié : '$($matchInfo.HomeTeam)'"
                                }
                                
                                if (-not [string]::IsNullOrEmpty($matchInfo.AwayTeam)) {
                                    # Même logique pour l'équipe visiteur
                                    if ($matchInfo.AwayTeam -match '^([A-Z]+(?:\s+\d+)?).*?(\d+U).*?([AB])') {
                                        $teamName = $matches[1].Trim()  # "TITANS 5" ou "JAYS"
                                        $ageGroup = $matches[2]         # "9U" ou "13U"
                                        $division = $matches[3]         # "B" ou "A"
                                        $matchInfo.AwayTeam = "$teamName $ageGroup$division"  # "TITANS 5 9UB" ou "JAYS 13UA"
                                    }
                                    Write-Host "DEBUG: AwayTeam simplifié : '$($matchInfo.AwayTeam)'"
                                }
                                
                                # Ajouter le match s'il a une heure valide
                                if (-not [string]::IsNullOrEmpty($matchInfo.Time)) {
                                    $matchesToday += $matchInfo
                                    Write-Host "DEBUG: ✅ Match ajouté : '$($matchInfo.HomeTeam)' vs '$($matchInfo.AwayTeam)' à '$($matchInfo.Time)'"
                                }
                                
                            } catch {
                                Write-Warning "Erreur lors de l'analyse d'une ligne : $_"
                            }
                        }
                    } else {
                        Write-Warning "❌ Aucun tableau trouvé pour la date d'aujourd'hui"
                    }
                } else {
                    Write-Warning "❌ Impossible de retrouver l'élément de date"
                }
                
            } catch {
                Write-Warning "Erreur lors de l'extraction des matchs : $_"
            }
        }
        
    } catch {
        Write-Error "Erreur CRITIQUE : $_"
        $SAFETY_MODE = $true
        $DATE_VALIDATED = $false
        $matchesToday = @()
    }
    
    # ÉTAPE 5 : RETOUR SÉCURISÉ
    Write-Host "DEBUG: === ÉTAPE 5 : RETOUR SÉCURISÉ ==="
    Write-Host "DEBUG: SAFETY_MODE final = $SAFETY_MODE"
    Write-Host "DEBUG: DATE_VALIDATED final = $DATE_VALIDATED"
    Write-Host "DEBUG: matchesToday.Count = $($matchesToday.Count)"
    
    # VÉRIFICATION FINALE ABSOLUE
    if ($SAFETY_MODE -eq $true) {
        Write-Host "DEBUG: 🛡️ SAFETY_MODE - Retour tableau vide garanti"
        $matchesToday = @()
    }
    
    if ($matchesToday.Count -gt 0 -and $DATE_VALIDATED -eq $false) {
        Write-Warning "🚨 INCOHÉRENCE DÉTECTÉE : Matchs trouvés sans validation de date !"
        Write-Warning "🚨 CORRECTION FORCÉE : Tableau vidé"
        $matchesToday = @()
    }
    
    Write-Host "DEBUG: === RETOUR FINAL ==="
    Write-Host "DEBUG: Nombre de matchs retournés : $($matchesToday.Count)"
    
    # RETOUR PROPRE - Seulement le tableau, pas les messages
    return $matchesToday
}

# Démarrer le navigateur Chrome via Selenium
try {
    # Créer les options Chrome
    $chromeOptions = New-Object OpenQA.Selenium.Chrome.ChromeOptions
    $chromeOptions.AddArgument("--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36")
    $chromeOptions.AddArgument("--accept-language=fr-FR,fr;q=0.9,en;q=0.8")
    $chromeOptions.AddArgument("--disable-blink-features=AutomationControlled")
    $chromeOptions.AddArgument("--disable-dev-shm-usage")
    $chromeOptions.AddArgument("--no-sandbox")
    $chromeOptions.AddArgument("--disable-extensions")
    $chromeOptions.AddArgument("--disable-plugins")
    $chromeOptions.AddArgument("--disable-images")
    $chromeOptions.AddArgument("--window-size=1920,1080")
    
    # Masquer les indicateurs d'automation
    $chromeOptions.AddExcludedArgument("enable-automation")
    $chromeOptions.AddAdditionalCapability("useAutomationExtension", $false)
    
    # Spécifier le chemin vers votre ChromeDriver 137
    $chromeDriverPath = ".\"  # Remplacez par votre chemin
    
    # Créer le service avec le bon chemin
    $chromeService = [OpenQA.Selenium.Chrome.ChromeDriverService]::CreateDefaultService($chromeDriverPath)
    
    # Créer le driver avec le service et les options
    $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($chromeService, $chromeOptions)
    Write-Output "Navigateur Chrome démarré avec ChromeDriver 137 et options anti-détection."
} catch {
    Write-Error "Erreur lors du démarrage de Chrome : $_"
    exit
}

try {
    # Se connecter à Spordle
    Write-Output "=== CONNEXION À SPORDLE ==="
    $driver.Navigate().GoToUrl($loginUrl)
    Write-Output "Page de connexion chargée : $loginUrl"
    Start-Sleep -Seconds 3

    # Saisir le username
    $usernameField = $driver.FindElementByName("username")
    $usernameField.SendKeys($loginname)
    Write-Output "Login name saisi."

    $usernameField.SendKeys([OpenQA.Selenium.Keys]::Enter)
    Write-Output "Connexion envoyée."
    Start-Sleep -Seconds 5

    # Saisir le mot de passe et soumettre
    $passwordField = $driver.FindElementByName("password")
    $passwordField.SendKeys($pass)
    Write-Output "Mot de passe saisi."
    
    $passwordField.SendKeys([OpenQA.Selenium.Keys]::Enter)
    Write-Output "Connexion envoyée."
    Start-Sleep -Seconds 5

    # Vérifier la connexion
    $currentUrl = $driver.Url
    Write-Output "URL après connexion : $currentUrl"
    
    if ($currentUrl -like "*play.spordle.com*") {
        Write-Output "✅ Connexion à Spordle réussie !"
        
        # Récupérer les matchs du jour
        Write-Output "=== RÉCUPÉRATION DES MATCHS ==="
        try {
            $matchesToday = Get-SpordleMatches -driver $driver -TestDate $testDate
            
            # VÉRIFICATION CRUCIALE : Valider que la fonction a fonctionné correctement
            if ($matchesToday -eq $null) {
                Write-Warning "🚨 La fonction Get-SpordleMatches a retourné null - Aucune publication"
                $matchesToday = @()
            }
            
            Write-Output "DEBUG: Fonction Get-SpordleMatches terminée avec $($matchesToday.Count) matchs"
            
        } catch {
            Write-Error "🚨 ERREUR dans Get-SpordleMatches : $_"
            Write-Output "🚨 Pour des raisons de sécurité, aucune publication ne sera effectuée"
            $matchesToday = @()
        }
        
        # VÉRIFICATION CRUCIALE : Ne rien publier si aucun match trouvé
        if ($matchesToday.Count -gt 0) {
            Write-Output "✅ $($matchesToday.Count) match(s) trouvé(s) pour aujourd'hui."
            Write-Output "=== CONSTRUCTION DU MESSAGE FACEBOOK ==="
            
            # Construire le message Facebook
            $currentDate = $TestDate.ToString("yyyy-MM-dd")  # Utiliser la date de test
            $introMessage = "Venez encourager nos Titans ! Voici les matchs de la journée sur nos terrains:`n`n"
            $tableHeader = "⚾ Matchs de la journée ($currentDate) ⚾`n`n"
            $tableContent = ""

            foreach ($match in $matchesToday) {
                # Traitement des noms d'équipes (déjà simplifiés par la fonction)
                $homeTeam = $match.HomeTeam
                $awayTeam = $match.AwayTeam
                $time = $match.Time
                $venue = $match.Venue -replace " - Baseball.*$", ""
                
                $tableContent += "⏰ $time  $homeTeam  vs  $awayTeam  🏟️ $venue`n"
            }

            $automatedMessage = "*** Ceci est un message automatisé, toujours valider l'horaire sur: https://page.spordle.com/fr/ligue-de-baseball-mineur-de-la-region-de-quebec/schedule-stats-standings ***"
            $message = $introMessage + $tableHeader + $tableContent + "`n$automatedMessage`n`nMerci à nos commanditaires !"

            Write-Output "=== PUBLICATION FACEBOOK ==="
            Write-Output "Message qui sera publié :"
            Write-Output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            Write-Output $message
            Write-Output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            # Récupérer les logos des commanditaires
            $imageFiles = Get-ChildItem -Path $commanditaireFolder -File | Where-Object { $_.Extension -in ".jpg", ".jpeg", ".png" }
            Write-Output "Fichiers de commanditaires trouvés : $($imageFiles.Count)"

            # Redimensionner les images
            $resizedImagePaths = @()
            foreach ($imageFile in $imageFiles) {
                $imagePath = $imageFile.FullName
                $tempImagePath = Join-Path $tempFolder "resized_$([System.IO.Path]::GetFileNameWithoutExtension($imagePath)).png"
                $success = Resize-Image -SourcePath $imagePath -DestinationPath $tempImagePath -TargetSize 1200 -TargetAspectRatio 1.0
                if ($success) {
                    $resizedImagePaths += $tempImagePath
                }
            }

            # Publier sur Facebook (même logique que le script original)
            try {
                # Publier le message texte
                $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($message)
                $messageEncoded = [System.Text.Encoding]::UTF8.GetString($messageBytes)

                $feedBody = @{
                    message = $messageEncoded
                    access_token = $accessToken
                    published = $true
                }
                $feedBodyJson = $feedBody | ConvertTo-Json -Depth 3 -Compress
                $response = Invoke-RestMethod -Uri $feedApiUrl -Method Post -Body $feedBodyJson -ContentType "application/json; charset=utf-8"
                $postId = $response.id
                Write-Output "✅ Publication Facebook réussie. Post ID : $postId"

                # Attacher les images si disponibles
                if ($resizedImagePaths.Count -gt 0) {
                    $attachedMedia = @()
                    foreach ($resizedImagePath in $resizedImagePaths) {
                        if (-not (Test-Path $resizedImagePath)) {
                            Write-Error "Image redimensionnée introuvable : $resizedImagePath"
                            continue
                        }

                        $photoBoundary = [System.Guid]::NewGuid().ToString()
                        $photoContentType = "multipart/form-data; boundary=$photoBoundary"

                        $photoBody = [System.IO.MemoryStream]::new()

                        # Déterminer le Content-Type (forcer PNG)
                        $contentTypeImage = "image/png"

                        # Ajouter la partie "source" pour l'image
                        $photoPartHeader = "--$photoBoundary`r`n" +
                                           "Content-Disposition: form-data; name=`"source`"; filename=`"$(Split-Path $resizedImagePath -Leaf)`"`r`n" +
                                           "Content-Type: $contentTypeImage`r`n" +
                                           "`r`n"
                        $photoBody.Write([System.Text.Encoding]::UTF8.GetBytes($photoPartHeader), 0, [System.Text.Encoding]::UTF8.GetByteCount($photoPartHeader))

                        # Ajouter les bytes de l'image
                        $photoImageBytes = [System.IO.File]::ReadAllBytes($resizedImagePath)
                        $photoBody.Write($photoImageBytes, 0, $photoImageBytes.Length)

                        # Ajouter la fin du boundary
                        $photoFooter = "`r`n--$photoBoundary--`r`n"
                        $photoBody.Write([System.Text.Encoding]::UTF8.GetBytes($photoFooter), 0, [System.Text.Encoding]::UTF8.GetByteCount($photoFooter))

                        $photoBodyBytes = $photoBody.ToArray()
                        $photoBody.Dispose()

                        # Publier l'image sans la rendre publique (published=false)
                        $photoResponse = Invoke-RestMethod -Uri "$photoApiUrl`?access_token=$accessToken&published=false" -Method Post -Body $photoBodyBytes -ContentType $photoContentType
                        $attachedMedia += @{ "media_fbid" = $photoResponse.id }
                    }

                    # Log du nombre d'images attachées
                    Write-Output "Nombre d'images attachées : $($attachedMedia.Count)"

                    # Mettre à jour la publication pour attacher les images
                    if ($attachedMedia.Count -gt 0) {
                        $updateUrl = "https://graph.facebook.com/v22.0/$postId"
                        $updateBody = @{
                            attached_media = $attachedMedia
                            access_token = $accessToken
                        } | ConvertTo-Json -Depth 3
                        Write-Output "Corps de la requête pour attacher les images : $updateBody"
                        Invoke-RestMethod -Uri $updateUrl -Method Post -Body $updateBody -ContentType "application/json; charset=utf-8" | Out-Null
                        Write-Output "✅ Images attachées avec succès à la publication."
                    }
                }

                Write-Output "✅ Publication complète réussie !"
            }
            catch {
                Write-Error "❌ Erreur lors de la publication Facebook : $_"
            }
        } else {
            # AUCUNE PUBLICATION - Affichage informatif seulement
            Write-Output ""
            Write-Output "❌ AUCUNE PUBLICATION FACEBOOK EFFECTUÉE"
            Write-Output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            Write-Output "ℹ️ Aucun match trouvé pour la date testée ($($TestDate.ToString('dddd, MMMM d, yyyy')))"
            Write-Output ""
            Write-Output "🔍 Raisons possibles :"
            Write-Output "   • Aucun match programmé pour cette date"
            Write-Output "   • La date dans Spordle ne correspond pas au format attendu" 
            Write-Output "   • Problème de connexion ou de chargement de la page"
            Write-Output "   • Structure de la page Spordle modifiée"
            Write-Output ""
            Write-Output "📋 Actions recommandées :"
            Write-Output "   • Vérifier manuellement s'il y a des matchs sur Spordle pour cette date"
            Write-Output "   • Consulter le fichier de debug généré : spordle_games_debug.html"
            Write-Output "   • Réessayer plus tard si c'est un problème temporaire"
            Write-Output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        }
    } else {
        Write-Warning "❌ Connexion à Spordle échouée. URL actuelle : $currentUrl"
    }
}
finally {
    # Fermer le navigateur
    $driver.Quit()
    Write-Output "Navigateur fermé."
    
    # Nettoyer les fichiers temporaires
    Remove-Item -Path "$tempFolder\resized_*" -Force -ErrorAction SilentlyContinue
}
