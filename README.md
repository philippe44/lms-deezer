# lms-deezer

## English Version

### Introduction

The `lms-deezer` project by Philippe44 allows you to connect [Logitech Media Server (LMS)](https://mysqueezebox.com/) to a Deezer account. This plugin enables LMS users to browse, search, and play Deezer songs directly from LMS.

### Installation

To install the `lms-deezer` plugin:

1. Open your Logitech Media Server (LMS).
2. Go to the server settings.
3. Navigate to the plugins tab.
4. Search for `lms-deezer` in the available plugins list.
5. Select `lms-deezer` and follow the on-screen instructions to install it.

> Note: MySqueezebox.com server has been shut down and we cannot find a way to connect the radios to the internet, so plugin installations are done directly from the LMS plugins list.

Don't forget to install blowfish crypto (`sudo apt-get install libcrypt-blowfish-perl` on Linux) or it will use pure Perl blowfish crypto which is **very** slow.

### Configuration

After installing the `lms-deezer` plugin, follow these steps to configure it:

1. Open your web browser and log in to [Deezer](https://www.deezer.com/).
2. Once logged in, open your browser's developer tools (usually F12 or Ctrl+Shift+I).
3. Go to the cookies tab and find the cookie named `arl` for `www.deezer.com`.
4. Copy the value of this cookie.
5. Go back to the `lms-deezer` plugin settings in LMS.
6. Paste the `arl` cookie value into the designated field.

If the ARL code is not entered, you will be able to browse song lists but will not be able to play the audio files.

### Usage

Once the `lms-deezer` plugin is installed and configured:

- You can access Deezer from your Logitech Media Server interface.
- Use the search and navigation features to find your favorite songs and playlists.
- Click on a song to start playback.

### Contributing

Contributions are welcome! To contribute:

1. Fork the repository on GitHub.
2. Create a branch for your feature (`git checkout -b feature/AmazingFeature`).
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`).
4. Push to the branch (`git push origin feature/AmazingFeature`).
5. Open a Pull Request.

For feature requests or bug reports, please use the GitHub repository's issues.

### License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

---

## Version Française

### Introduction

Le projet `lms-deezer` de Philippe44 permet de connecter le [Logitech Media Server (LMS)](https://mysqueezebox.com/) à un compte Deezer. Ce plugin permet aux utilisateurs de LMS de naviguer, rechercher et lire des chansons de Deezer directement à partir de LMS.

### Installation

Pour installer le plugin `lms-deezer` :

1. Ouvrez votre Logitech Media Server (LMS).
2. Allez dans les paramètres du serveur.
3. Rendez-vous dans l'onglet des plugins.
4. Recherchez `lms-deezer` dans la liste des plugins disponibles.
5. Sélectionnez `lms-deezer` et suivez les instructions à l'écran pour l'installer.

> Note : Le serveur MySqueezebox.com a été arrêté et nous ne trouvons pas de moyen de connecter les radios à Internet, donc l'installation des plugins se fait directement depuis la liste des plugins de LMS.

N'oubliez pas d'installer le cryptage blowfish (`sudo apt-get install libcrypt-blowfish-perl` sur Linux) sinon il utilisera le cryptage blowfish pur Perl qui est **très** lent.

### Configuration

Après avoir installé le plugin `lms-deezer`, suivez ces étapes pour le configurer :

1. Ouvrez votre navigateur web et connectez-vous à [Deezer](https://www.deezer.com/).
2. Une fois connecté, ouvrez les outils de développement de votre navigateur (généralement F12 ou Ctrl+Shift+I).
3. Allez dans l'onglet des cookies et trouvez le cookie nommé `arl` pour `www.deezer.com`.
4. Copiez la valeur de ce cookie.
5. Retournez dans les paramètres du plugin `lms-deezer` dans LMS.
6. Collez la valeur du cookie `arl` dans le champ prévu à cet effet.

Si le code ARL n'est pas entré, vous pourrez naviguer dans les listes de chansons mais vous ne pourrez pas lire les fichiers audio.

### Utilisation

Une fois le plugin `lms-deezer` installé et configuré :

- Vous pouvez accéder à Deezer depuis l'interface de votre Logitech Media Server.
- Utilisez les fonctionnalités de recherche et de navigation pour trouver vos chansons et playlists préférées.
- Cliquez sur une chanson pour commencer la lecture.

### Contribuer

Les contributions sont les bienvenues ! Pour contribuer :

1. Forkez le dépôt sur GitHub.
2. Créez une branche pour votre fonctionnalité (`git checkout -b feature/AmazingFeature`).
3. Committez vos modifications (`git commit -m 'Add some AmazingFeature'`).
4. Poussez vers la branche (`git push origin feature/AmazingFeature`).
5. Ouvrez une Pull Request.

Pour des demandes de fonctionnalités ou des rapports de bugs, veuillez utiliser les issues du dépôt GitHub.

### Licence

Ce projet est sous licence MIT. Voir le fichier [LICENSE](LICENSE) pour plus de détails.
