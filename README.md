🕵️‍♂️ Unnamed INTagram


Unnamed INTagram è un tool OSINT da terminale per profili Instagram.

Permette di:




configurare e salvare automaticamente il proprio sessionid (cookie dopo il login);




ottenere dettagli completi da USERNAME o ID numerico;




esportare i risultati in un file TXT ordinato sul Desktop (anche con campi sensibili);




scaricare l’intero profilo: immagine di profilo, foto, caroselli, video e reels (dal primo all’ultimo post), con manifest di supporto;




aggiornarsi facilmente tramite update.sh.




⚠️ Nota: richiede di aver effettuato il login su instagram.com
 dal proprio browser. Il sessionid può scadere o essere invalidato (logout, cambio password, ecc.): in quel caso basta riconfiguralo.



🚀 Installazione




Scarica il file install_intagram.sh




Apri il terminale nella cartella dove si trova il file




Lancia:






chmod +x install_intagram.sh
bash install_intagram.sh
source ~/.bashrc





Avvia con:






intagram




📋 Menu interattivo




==== Unnamed INTagram ====
[1] Configurazione sessionID
[2] Info da USERNAME
[3] Info da ID
[4] Stato
[5] Aggiorna / Ripara
[6] Scarica profilo intero (foto/video)
[0] Esci





1: guida passo passo alla configurazione del sessionid (auto o manuale).




2 / 3: ricerca da username o ID con tabella ordinata, esportabile in TXT.




4: mostra stato sessionID e ultima configurazione.




5: aggiorna/ripara l’ambiente.




6: scarica tutto il profilo (foto profilo, immagini, caroselli, video, reels).





📂 Download profilo


I contenuti vengono salvati in:




~/OSINT Tool/intagram/downloads/<username>_<timestamp>/





profile.jpg → immagine profilo




manifest.txt → log con ID post, data, tipo, link, caption




<postid>.jpg o .mp4 → media singoli




<postid>_1.jpg, <postid>_2.mp4 … → media dei caroselli





⚖️ Disclaimer


Questo strumento utilizza API non ufficiali.

L’uso è destinato a fini di analisi OSINT, investigativi o di ricerca.

Il download di contenuti può violare i Termini di Servizio di Instagram e i diritti d’autore.

Assicurati di avere titolo, consenso o legittimo interesse per l’utilizzo.
