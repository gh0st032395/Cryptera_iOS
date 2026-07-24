import UniformTypeIdentifiers

extension UTType {
    /// Il tipo dei file Cryptera (SPEC §6.5).
    ///
    /// È dichiarato come **esportato** in `Info.plist`
    /// (`UTExportedTypeDeclarations`): il formato è nostro, non di terzi.
    /// `UTType(exportedAs:)` richiede che la dichiarazione esista davvero nel
    /// bundle — se manca, l'inizializzatore termina il processo invece di
    /// tornare `nil`. È voluto: un `.plist` incoerente deve emergere subito, e
    /// `DocumentTypesTests` lo verifica prima che possa arrivare in mano a
    /// qualcuno.
    static let crypteraECF = UTType(exportedAs: "com.cryptera.ecf", conformingTo: .data)
}
