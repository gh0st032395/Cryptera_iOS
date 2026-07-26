import UIKit

/// Tiene l'app sveglia e viva per la durata di un'operazione (SPEC §11.1).
///
/// Risolve due problemi distinti che hanno la stessa causa — iOS sospende le
/// app che non stanno visibilmente lavorando:
///
/// 1. **Lo schermo si spegne durante l'operazione.** Cifrare una cartella
///    grande richiede minuti in cui l'utente non tocca nulla: senza
///    `isIdleTimerDisabled` il telefono si blocca da solo e l'app viene
///    sospesa a metà lavoro, per inattività che inattività non è.
///
/// 2. **L'app va in secondo piano.** Senza un background task iOS concede
///    pochi secondi e poi sospende il processo *dove si trova*, cioè
///    potenzialmente a metà di una scrittura. Con il task il tempo sale
///    all'ordine della decina di secondi, e soprattutto si ottiene un
///    **avviso quando sta per scadere**.
///
/// Quell'avviso è la parte importante. Alla scadenza si **annulla**
/// l'operazione invece di lasciarla sospendere: la cancellazione ha già un
/// percorso di pulizia che rimuove l'output parziale, mentre una sospensione a
/// metà scrittura lascerebbe un file troncato — che per un `.ecf` significa un
/// archivio che sembra esserci e non si apre.
///
/// Vive sul main actor perché `UIApplication` è lì, e sta in un tipo suo invece
/// che dentro le schermate perché le operazioni partono da tre posti diversi
/// (Cifra, Decifra, Batch) e la logica scritta tre volte divergerebbe.
@MainActor
final class OperationLifetime {
    static let shared = OperationLifetime()

    /// Quante operazioni sono in corso. È un **contatore**, non un booleano: il
    /// batch ne esegue una dopo l'altra, e con un booleano la fine della prima
    /// riaccenderebbe il blocco schermo per tutte le successive.
    private var active = 0

    /// Token delle operazioni in corso, per poterle annullare alla scadenza.
    /// Non tutte ne hanno uno: chi non lo passa non è annullabile e alla
    /// scadenza verrà semplicemente sospeso.
    private var tokens: [CancelToken] = []

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func begin(token: CancelToken?) {
        if let token { tokens.append(token) }
        active += 1
        guard active == 1 else { return }

        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "com.cryptera.operation"
        ) { [weak self] in
            // Chiamato da iOS **sul main thread** quando il tempo sta per
            // finire. Se non si finisce qui, il processo viene terminato.
            self?.expire()
        }
    }

    func end(token: CancelToken?) {
        if let token, let indice = tokens.firstIndex(where: { $0 === token }) {
            tokens.remove(at: indice)
        }
        // Mai sotto zero: uno sbilanciamento lascerebbe lo schermo sempre acceso
        // o un background task mai chiuso, che iOS punisce terminando l'app.
        active = max(0, active - 1)
        guard active == 0 else { return }
        release()
    }

    /// iOS ha esaurito il tempo concesso.
    private func expire() {
        for token in tokens {
            token.cancel()
        }
        tokens.removeAll()
        // Il contatore lo azzerano le `end` delle operazioni annullate, che
        // arrivano comunque: qui si rilascia solo ciò che iOS sta per
        // reclamare, altrimenti il task resterebbe aperto oltre la scadenza.
        release()
    }

    private func release() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    #if DEBUG
    /// Solo per i test: stato osservabile senza esporre i dettagli.
    var isHoldingDevice: Bool { active > 0 }
    var activeCount: Int { active }

    /// Simula la scadenza concessa da iOS, che in un test non si può provocare.
    func simulateExpirationForTesting() { expire() }

    /// Riporta allo stato iniziale fra un test e l'altro.
    func resetForTesting() {
        tokens.removeAll()
        active = 0
        release()
    }
    #endif
}
