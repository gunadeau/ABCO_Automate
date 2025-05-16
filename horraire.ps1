

$scriptDir = $PSScriptRoot  # Répertoire où le script est exécuté
$excelFilePath = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "horraire.xlsx"))
$commanditaireFolder = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "commanditaire"))
$tempFolder = [System.IO.Path]::GetFullPath((Join-Path $scriptDir "temp"))
$pageId = $env:FACEBOOK_PAGE_ID
$accessToken = $env:FACEBOOK_ACCESS_TOKEN
$photoApiUrl = "https://graph.facebook.com/v20.0/$pageId/photos"
$feedApiUrl = "https://graph.facebook.com/v20.0/$pageId/feed"


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
        [int]$TargetSize = 1200,  # Taille cible augmentée à 1200x1200 pixels
        [float]$TargetAspectRatio = 1.0  # Ratio d'aspect cible (1:1 pour un carré)
    )

    try {
        # Vérifier si le fichier existe et est accessible
        if (-not (Test-Path $SourcePath)) {
            Write-Warning "Le fichier $SourcePath n'existe pas ou n'est pas accessible."
            return $false
        }

        # Charger l'image source
        $image = [System.Drawing.Image]::FromFile($SourcePath)
        $originalWidth = $image.Width
        $originalHeight = $image.Height

        # Vérifier que les dimensions originales sont valides
        if ($originalWidth -le 0 -or $originalHeight -le 0) {
            Write-Warning "Dimensions invalides pour l'image $SourcePath : Largeur=$originalWidth, Hauteur=$originalHeight"
            $image.Dispose()
            return $false
        }

        $originalAspectRatio = $originalWidth / $originalHeight
        Write-Output "Image $SourcePath : Largeur=$originalWidth, Hauteur=$originalHeight, Ratio=$originalAspectRatio"

        # Vérifier si l'image originale est plus petite que la taille cible
        if ($originalWidth -lt $TargetSize -or $originalHeight -lt $TargetSize) {
            Write-Warning "L'image originale $SourcePath est plus petite que la taille cible ($TargetSize x $TargetSize). Cela peut entraîner une perte de qualité (upscaling)."
        }

        # Calculer les dimensions pour le redimensionnement (sans dépasser TargetSize)
        if ($originalAspectRatio -gt $TargetAspectRatio) {
            # Image plus large que haute : ajuster la hauteur
            $newWidth = $TargetSize
            $newHeight = [math]::Round($TargetSize / $originalAspectRatio)
        } else {
            # Image plus haute que large : ajuster la largeur
            $newHeight = $TargetSize
            $newWidth = [math]::Round($TargetSize * $originalAspectRatio)
        }

        # S'assurer que les dimensions sont au moins 1 pixel
        $newWidth = [math]::Max(1, $newWidth)
        $newHeight = [math]::Max(1, $newHeight)
        Write-Output "Nouvelles dimensions pour $SourcePath : Largeur=$newWidth, Hauteur=$newHeight"

        # Créer une image temporaire redimensionnée
        $tempImage = New-Object System.Drawing.Bitmap $newWidth, $newHeight
        $graphics = [System.Drawing.Graphics]::FromImage($tempImage)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.DrawImage($image, 0, 0, $newWidth, $newHeight)

        # Créer une image finale carrée (TargetSize x TargetSize) avec un fond blanc
        $finalImage = New-Object System.Drawing.Bitmap $TargetSize, $TargetSize
        $finalGraphics = [System.Drawing.Graphics]::FromImage($finalImage)
        $finalGraphics.Clear([System.Drawing.Color]::White)  # Fond blanc
        $xOffset = [math]::Round(($TargetSize - $newWidth) / 2)
        $yOffset = [math]::Round(($TargetSize - $newHeight) / 2)
        $finalGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $finalGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $finalGraphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $finalGraphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $finalGraphics.DrawImage($tempImage, $xOffset, $yOffset, $newWidth, $newHeight)

        # Sauvegarder l'image redimensionnée en PNG pour éviter la perte de qualité
        $finalImage.Save($DestinationPath, [System.Drawing.Imaging.ImageFormat]::Png)

        # Vérifier la taille du fichier généré
        $fileInfo = Get-Item $DestinationPath
        Write-Output "Image redimensionnée sauvegardée : $DestinationPath (Taille : $($fileInfo.Length / 1KB) KB)"

        # Nettoyer les ressources
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

# Importer le module ImportExcel
Import-Module ImportExcel

$excelEpoch = [DateTime]::Parse("1899-12-30")

# Obtenir la date du jour
$currentDate = (Get-Date).ToString("yyyy-MM-dd")  # Format: 2025-05-14

# Lire le fichier Excel
$matches = Import-Excel -Path $excelFilePath
Write-Output "Propriétés des matchs importés :"
$matches[0] | Get-Member -MemberType NoteProperty | ForEach-Object { Write-Output $_.Name }

# Filtrer les matchs du jour et trier par heure
$matchesToday = $matches | Where-Object { 
    try { 
        [DateTime]::Parse($_.Date).ToString("yyyy-MM-dd") -eq $currentDate 
    } catch { 
        $false 
    }
} | Sort-Object { 
    try { 
        $startTime = $_.'Start Time'
        if ($startTime -is [double]) {
            # Convertir la fraction de jour en heure
            $excelEpoch = [DateTime]::Parse("1899-12-30")
            $excelEpoch.AddDays($startTime).ToString("HH:mm")
        } else {
            Write-Warning "Start Time '$startTime' n'est pas une fraction de jour (Type : $($startTime.GetType().FullName))"
            "00:00"  # Valeur par défaut pour les cas inattendus
        }
    } catch { 
        Write-Warning "Erreur de conversion pour Start Time '$startTime' : $_"
        "00:00"  # Valeur par défaut en cas d'erreur
    }
}

if ($matchesToday) {
    # Construire le tableau des matchs avec un format visuel
    $introMessage = "Venez encourager nos Titans ! Voici les matchs de la journée`n`n"
    $tableHeader = "⚾ Matchs de la journée ($currentDate) ⚾`n`n"
    $tableContent = ""

    foreach ($match in $matchesToday) {
        $startTime = try { 
            $startTimeValue = $match.'Start Time'
            if ($startTimeValue -is [double]) {
                # Convertir la fraction de jour en heure
                $excelEpoch = [DateTime]::Parse("1899-12-30")
                $excelEpoch.AddDays($startTimeValue).ToString("HH:mm")
            } else {
                Write-Warning "Start Time '$startTimeValue' n'est pas une fraction de jour (Type : $($startTimeValue.GetType().FullName))"
                "Inconnu"  # Valeur par défaut pour les cas inattendus
            }
        } catch { 
            Write-Warning "Erreur de conversion pour Start Time '$startTimeValue' : $_"
            "Inconnu"  # Valeur par défaut en cas d'erreur
        }
        $fullHomeTeam = $match."Home Team Name"
        $fullAwayTeam = $match."Away Team Name"
        
        # Log des noms complets pour vérification
        Write-Output "Nom brut (Home Team) : '$fullHomeTeam'"
        Write-Output "Nom brut (Away Team) : '$fullAwayTeam'"

        # Normaliser le délimiteur : remplacer les tirets entourés d'espaces par un tiret simple
        $normalizedHomeTeam = $fullHomeTeam -replace '\s*-\s*', '-'
        $normalizedAwayTeam = $fullAwayTeam -replace '\s*-\s*', '-'

        # Log des noms après normalisation
        Write-Output "Nom normalisé (Home Team) : '$normalizedHomeTeam'"
        Write-Output "Nom normalisé (Away Team) : '$normalizedAwayTeam'"

        # Extraire les trois premières parties du nom
        $homeTeamParts = $normalizedHomeTeam.Split('-') | Select-Object -First 3
        $awayTeamParts = $normalizedAwayTeam.Split('-') | Select-Object -First 3

        # Log des parties pour vérification
        Write-Output "Parties (Home Team) : $($homeTeamParts -join ', ')"
        Write-Output "Parties (Away Team) : $($awayTeamParts -join ', ')"

        # Recombiner les parties dans le nouveau format : "TITANS 2 9UA"
        if ($homeTeamParts.Length -eq 3) {
            $homeTeamBase = $homeTeamParts[0]  # Ex: "TITANS 2" (déjà correct, car il y a un espace dans le nom)
            $homeTeamLevelAndCategory = $homeTeamParts[1] + $homeTeamParts[2]  # Ex: "9UA"
            $homeTeam = "$homeTeamBase $homeTeamLevelAndCategory"  # Ex: "TITANS 2 9UA"
        } else {
            $homeTeam = $homeTeamParts -join " "  # Cas où il n'y a pas assez de parties
        }

        if ($awayTeamParts.Length -eq 3) {
            $awayTeamBase = $awayTeamParts[0]  # Ex: "CARDINALS 1" (déjà correct, car il y a un espace dans le nom)
            $awayTeamLevelAndCategory = $awayTeamParts[1] + $awayTeamParts[2]  # Ex: "9UA"
            $awayTeam = "$awayTeamBase $awayTeamLevelAndCategory"  # Ex: "CARDINALS 1 9UA"
        } else {
            $awayTeam = $awayTeamParts -join " "  # Cas où il n'y a pas assez de parties
        }
        
        # Log des noms après traitement
        Write-Output "Nom affiché (Home Team) : '$homeTeam'"
        Write-Output "Nom affiché (Away Team) : '$awayTeam'"

        # Nettoyer le nom du lieu (Venue) : supprimer " - Baseball" et tout ce qui suit
        $venue = $match.Venue
        Write-Output "Lieu brut : '$venue'"
        if ($venue -match " - Baseball") {
            $venue = $venue -replace " - Baseball.*$", ""
        }
        Write-Output "Lieu nettoyé : '$venue'"

        $tableContent += "⏰ $startTime  $homeTeam  vs  $awayTeam  🏟️ $venue`n"
    }

    # Ajouter le message automatisé et les remerciements aux commanditaires
    $automatedMessage = "*** Ceci est un message automatisé, toujours valider l'horraire sur: https://page.spordle.com/fr/ligue-de-baseball-mineur-de-la-region-de-quebec/schedule-stats-standings ***"
    $message = $introMessage + $tableHeader + $tableContent + "`n$automatedMessage`n`nMerci à nos commanditaires !"

    # Récupérer les logos des commanditaires
    Write-Output "Recherche des fichiers dans : $commanditaireFolder"
    $imageFiles = Get-ChildItem -Path $commanditaireFolder -File | Where-Object { $_.Extension -in ".jpg", ".jpeg", ".png" }
    Write-Output "Fichiers trouvés : $($imageFiles.Count)"
    if ($imageFiles.Count -eq 0) {
        Write-Error "Aucun logo de commanditaire trouvé dans : $commanditaireFolder"
        Get-ChildItem -Path $commanditaireFolder | ForEach-Object { Write-Output "Fichier détecté : $($_.Name)" }
        exit
    }

    # Lister les fichiers trouvés pour vérification
    Write-Output "Liste des fichiers trouvés :"
    $imageFiles | ForEach-Object { Write-Output "- $($_.FullName)" }

    # Redimensionner les images et créer des copies temporaires
    $resizedImagePaths = @()
    foreach ($imageFile in $imageFiles) {
        $imagePath = $imageFile.FullName
        $tempImagePath = Join-Path $tempFolder "resized_$([System.IO.Path]::GetFileNameWithoutExtension($imagePath)).png"  # Correction pour compatibilité
        $success = Resize-Image -SourcePath $imagePath -DestinationPath $tempImagePath -TargetSize 1200 -TargetAspectRatio 1.0
        if ($success) {
            $resizedImagePaths += $tempImagePath
        } else {
            Write-Warning "L'image $imagePath n'a pas pu être redimensionnée et sera ignorée."
        }
    }

    # Vérifier s'il y a des images valides après redimensionnement
    Write-Output "Nombre d'images redimensionnées avec succès : $($resizedImagePaths.Count)"
    if ($resizedImagePaths.Count -eq 0) {
        Write-Warning "Aucune image valide n'a pu être redimensionnée. La publication sera effectuée sans images."
    }

    try {
        # Étape 1 : Publier uniquement le message texte via /feed
        # Forcer l'encodage UTF-8 pour le message
        $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($message)
        $messageEncoded = [System.Text.Encoding]::UTF8.GetString($messageBytes)

        $feedBody = @{
            message = $messageEncoded
            access_token = $accessToken
        }
        $feedBodyJson = $feedBody | ConvertTo-Json -Depth 3 -Compress
        Write-Output "Corps de la requête pour /feed : $feedBodyJson"
        $response = Invoke-RestMethod -Uri $feedApiUrl -Method Post -Body $feedBodyJson -ContentType "application/json; charset=utf-8"
        $postId = $response.id
        Write-Output "Publication texte réussie. Post ID : $postId"

        # Étape 2 : Publier les images redimensionnées et les attacher à la publication
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

        # Étape 3 : Mettre à jour la publication pour attacher les images
        if ($attachedMedia.Count -gt 0) {
            $updateUrl = "https://graph.facebook.com/v20.0/$postId"
            $updateBody = @{
                attached_media = $attachedMedia
                access_token = $accessToken
            } | ConvertTo-Json -Depth 3
            Write-Output "Corps de la requête pour attacher les images : $updateBody"
            Invoke-RestMethod -Uri $updateUrl -Method Post -Body $updateBody -ContentType "application/json; charset=utf-8" | Out-Null
            Write-Output "Images attachées avec succès à la publication."
        }

        Write-Output "Publication réussie : $message"
    }
    catch {
        Write-Error "Erreur lors de la publication : $_"
    }
    finally {
        # Nettoyer les fichiers temporaires
        Remove-Item -Path "$tempFolder\resized_*" -Force -ErrorAction SilentlyContinue
    }
}
else {
    Write-Output "Aucun match aujourd'hui ($currentDate)."
}
