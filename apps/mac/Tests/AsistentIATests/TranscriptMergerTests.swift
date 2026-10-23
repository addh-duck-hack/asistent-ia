import Testing
@testable import AsistentIA

@Test func mergesTracksInTimeOrder() {
    let merged = TranscriptMerger.merge(
        me: [TimedText(start: 0, end: 3, text: "Buenos días, ¿cómo van?"), TimedText(start: 10, end: 12, text: "Perfecto.")],
        others: [TimedText(start: 4, end: 9, text: "Bien, ya quedó el endpoint de pagos.")]
    )
    #expect(merged.map(\.speaker) == ["me", "others", "me"])
    #expect(merged.map(\.text) == ["Buenos días, ¿cómo van?", "Bien, ya quedó el endpoint de pagos.", "Perfecto."])
    #expect(merged[1].startSec == 4)
}

@Test func dropsMicEchoOfSystemAudio() {
    let merged = TranscriptMerger.merge(
        me: [TimedText(start: 4.3, end: 9.1, text: "bien ya quedo el endpoint de pagos")],
        others: [TimedText(start: 4, end: 9, text: "Bien, ya quedó el endpoint de pagos.")]
    )
    #expect(merged.count == 1)
    #expect(merged[0].speaker == "others")
}

@Test func keepsMicWhenItSaysSomethingDifferentAtTheSameTime() {
    let merged = TranscriptMerger.merge(
        me: [TimedText(start: 5, end: 7, text: "Ok, yo hablo con infraestructura.")],
        others: [TimedText(start: 4, end: 9, text: "Sigo sin acceso a Stripe.")]
    )
    #expect(merged.count == 2)
}

@Test func filtersWhisperHallucinationsAndRepeats() {
    let cleaned = TranscriptMerger.clean([
        TimedText(start: 0, end: 2, text: "Subtítulos realizados por la comunidad de Amara.org"),
        TimedText(start: 2, end: 4, text: "<|es|> Arrancamos con la daily."),
        TimedText(start: 4, end: 6, text: "arrancamos con la daily"),
        TimedText(start: 6, end: 8, text: "  "),
        TimedText(start: 8, end: 10, text: "Gracias por ver"),
    ])
    #expect(cleaned == [TimedText(start: 2, end: 4, text: "Arrancamos con la daily.")])
}
