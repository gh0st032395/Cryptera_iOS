import XCTest
@testable import Cryptera

/// Schermo sveglio e background task durante le operazioni (M10, SPEC §11.1).
@MainActor
final class OperationLifetimeTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        OperationLifetime.shared.resetForTesting()
    }

    override func tearDown() async throws {
        OperationLifetime.shared.resetForTesting()
        try await super.tearDown()
    }

    func testTieneIlDispositivoSoloMentreQualcosaGira() {
        let lifetime = OperationLifetime.shared
        XCTAssertFalse(lifetime.isHoldingDevice, "a riposo non deve trattenere nulla")

        lifetime.begin(token: nil)
        XCTAssertTrue(lifetime.isHoldingDevice)

        lifetime.end(token: nil)
        XCTAssertFalse(lifetime.isHoldingDevice, "finita l'operazione va rilasciato")
    }

    /// Il caso del batch: operazioni in sequenza, non annidate.
    ///
    /// Con un booleano al posto del contatore la fine della prima spegnerebbe
    /// il blocco schermo mentre le altre stanno ancora lavorando — e il
    /// telefono si bloccherebbe a metà coda, che è esattamente lo scenario per
    /// cui questo tipo esiste.
    func testConteggioSopravviveAOperazioniSovrapposte() {
        let lifetime = OperationLifetime.shared
        let primo = CancelToken()
        let secondo = CancelToken()

        lifetime.begin(token: primo)
        lifetime.begin(token: secondo)
        XCTAssertEqual(lifetime.activeCount, 2)

        lifetime.end(token: primo)
        XCTAssertTrue(
            lifetime.isHoldingDevice,
            "una sola operazione conclusa non deve rilasciare: l'altra sta ancora lavorando"
        )

        lifetime.end(token: secondo)
        XCTAssertFalse(lifetime.isHoldingDevice)
    }

    /// Uno sbilanciamento non deve mandare il contatore sotto zero.
    ///
    /// Un contatore negativo terrebbe lo schermo acceso per sempre e lascerebbe
    /// un background task mai chiuso, che iOS punisce terminando l'app: il
    /// sintomo comparirebbe lontano dalla causa.
    func testEndDiPiuNonPortaIlContatoreSottoZero() {
        let lifetime = OperationLifetime.shared
        lifetime.begin(token: nil)
        lifetime.end(token: nil)
        lifetime.end(token: nil)
        XCTAssertEqual(lifetime.activeCount, 0)

        lifetime.begin(token: nil)
        XCTAssertTrue(lifetime.isHoldingDevice, "dopo uno sbilanciamento deve ancora funzionare")
        lifetime.end(token: nil)
        XCTAssertFalse(lifetime.isHoldingDevice)
    }

    /// Alla scadenza del tempo concesso, le operazioni vengono **annullate**.
    ///
    /// È il punto della milestone: sospendere a metà scrittura lascerebbe un
    /// `.ecf` troncato — un archivio che sembra esserci e non si apre — mentre
    /// la cancellazione ha già un percorso di pulizia che rimuove l'output
    /// parziale.
    func testLaScadenzaAnnullaLeOperazioniInCorso() {
        let lifetime = OperationLifetime.shared
        let token = CancelToken()
        XCTAssertFalse(token.isCancelled(), "premessa: il token parte non annullato")

        lifetime.begin(token: token)
        lifetime.simulateExpirationForTesting()

        XCTAssertTrue(
            token.isCancelled(),
            "scaduto il tempo concesso da iOS, l'operazione va annullata e non sospesa a metà"
        )
    }

    /// Chi non passa un token non è annullabile: la scadenza non deve andare in
    /// crisi per questo, né trattenere il dispositivo dopo.
    func testScadenzaSenzaTokenNonTrattieneIlDispositivo() {
        let lifetime = OperationLifetime.shared
        lifetime.begin(token: nil)
        lifetime.simulateExpirationForTesting()
        lifetime.end(token: nil)
        XCTAssertFalse(lifetime.isHoldingDevice)
    }
}
