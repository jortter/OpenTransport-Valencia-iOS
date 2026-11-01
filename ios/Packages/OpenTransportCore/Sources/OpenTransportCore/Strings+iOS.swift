import Foundation

/// Texts that only the iOS app needs (not present in Language.kt).
extension Strings {
    public var arrivals: String { pick("Llegadas", "Arrivals", "Arribades") }
    public var loading: String { pick("Cargando…", "Loading…", "Carregant…") }
    public var comingSoon: String { pick("Próximamente en iOS", "Coming soon on iOS", "Pròximament en iOS") }
    public var stopCode: String { pick("Parada", "Stop", "Parada") }
    public var refresh: String { pick("Actualizar", "Refresh", "Actualitzar") }

    public func busTitle(_ number: Int) -> String { pick("Autobús \(number)", "Bus \(number)", "Autobús \(number)") }
    public var nextStops: String { pick("Próximas paradas", "Next stops", "Pròximes parades") }
    public var view3D: String { pick("Vista 3D", "3D view", "Vista 3D") }
    public var centerOnBus: String { pick("Centrar en el bus", "Centre on the bus", "Centra en el bus") }

    public var mechanicalBikes: String { pick("Mecánicas", "Mechanical", "Mecàniques") }
    public var electricBikes: String { pick("Eléctricas", "Electric", "Elèctriques") }
    public func bikeTitle(_ number: Int) -> String { pick("Bici \(number)", "Bike \(number)", "Bici \(number)") }
    public func standTitle(_ number: Int) -> String { pick("Anclaje \(number)", "Stand \(number)", "Ancoratge \(number)") }

    public var aboutUnofficial: String {
        pick("App no oficial. Sin relación con EMT València, Metrovalencia / FGV, ATMV / Met GO, Valenbisi / JCDecaux, el Ajuntament de València ni ningún otro operador. Las marcas y logotipos pertenecen a sus propietarios.",
             "Unofficial app. Not affiliated with, endorsed by, or connected to EMT València, Metrovalencia / FGV, ATMV / Met GO, Valenbisi / JCDecaux, the Ajuntament de València or any other operator or company. All trademarks and logos belong to their respective owners.",
             "App no oficial. Sense relació amb EMT València, Metrovalencia / FGV, ATMV / Met GO, Valenbisi / JCDecaux, l'Ajuntament de València ni cap altre operador. Les marques i logotips pertanyen als seus propietaris.")
    }

    public var aboutData: String {
        pick("Datos en directo y mapas de fuentes públicas y herramientas de la comunidad: EMT València, Metrovalencia (metrovalencia.es, metroapi.alexbadi.es), Valenbisi (JCDecaux), Renfe, datos abiertos de València (CC BY 4.0), colaboradores de OpenStreetMap (ODbL), CARTO y MapLibre. FOSSGIS proporciona las rutas a pie.",
             "Live data and maps come from public/open sources and community tools, including EMT València, Metrovalencia (metrovalencia.es, metroapi.alexbadi.es), Valenbisi via JCDecaux, Renfe, València open data (CC BY 4.0), OpenStreetMap contributors (ODbL), CARTO basemaps and MapLibre. FOSSGIS provides the walking routes.",
             "Dades en directe i mapes de fonts públiques i eines de la comunitat: EMT València, Metrovalencia (metrovalencia.es, metroapi.alexbadi.es), Valenbisi (JCDecaux), Renfe, dades obertes de València (CC BY 4.0), col·laboradors d'OpenStreetMap (ODbL), CARTO i MapLibre. FOSSGIS proporciona les rutes a peu.")
    }

    public var aboutWarranty: String {
        pick("Se ofrece «tal cual», sin garantía; los tiempos y posiciones pueden llegar con retraso o ser inexactos. Usa la información oficial de los operadores para decidir tus viajes.",
             "Provided “as is”, without warranty; times and positions may be delayed or inaccurate. Use the official operators' information for travel decisions.",
             "S'ofereix «tal qual», sense garantia; els temps i posicions poden arribar amb retard o ser inexactes. Usa la informació oficial dels operadors per a decidir els teus viatges.")
    }

    public func nextLabel(_ value: String) -> String { pick("Próxima: \(value)", "Next: \(value)", "Pròxima: \(value)") }

    /// Valenbisi summary (Android's `placeSubtitle`).
    public func bikesSummary(available: Int, free: Int, open: Bool) -> String {
        if !open { return closed }
        if available <= 0 { return pick("Sin bicis · \(free) anclajes libres", "No bikes · \(free) free docks", "Sense bicis · \(free) ancoratges lliures") }
        if free <= 0 { return pick("\(available) bicis · sin anclajes libres", "\(available) bikes · no free docks", "\(available) bicis · sense ancoratges lliures") }
        return pick("\(available) bicis · \(free) anclajes libres", "\(available) bikes · \(free) free docks", "\(available) bicis · \(free) ancoratges lliures")
    }

    public var alertsWhileOpen: String {
        pick("En iPhone los avisos funcionan mientras la app está abierta o en segundo plano reciente.",
             "On iPhone alerts work while the app is open or recently in the background.",
             "En iPhone els avisos funcionen mentre l'app està oberta o en segon pla recent.")
    }

    // Trip planner
    public var planning: String { pick("Planificando…", "Planning…", "Planificant…") }
    public var direct: String { pick("directo", "direct", "directe") }
    public func transfers(_ count: Int) -> String {
        count == 1 ? pick("1 transbordo", "1 transfer", "1 transbord") : pick("\(count) transbordos", "\(count) transfers", "\(count) transbords")
    }
    public func walkTotal(_ meters: Int) -> String { pick("a pie \(meters) m", "walk \(meters) m", "a peu \(meters) m") }
    public func walkLeg(_ minutes: Int, _ meters: Int) -> String {
        pick("A pie \(minutes) min · \(meters) m", "Walk \(minutes) min · \(meters) m", "A peu \(minutes) min · \(meters) m")
    }
    public func towards(_ name: String) -> String { pick("hacia \(name)", "towards \(name)", "cap a \(name)") }
    public func rideLeg(board: String, stops: Int, minutes: Int) -> String {
        pick("sube en \(board) · \(stops) paradas · \(minutes) min",
             "board \(board) · \(stops) stops · ride \(minutes) min",
             "puja a \(board) · \(stops) parades · \(minutes) min")
    }
    public var noRoutes: String { pick("No hay rutas con estas paradas", "No routes between these stops", "No hi ha rutes entre estes parades") }
    public var beta: String { "BETA" }

    public var liveBusesTitle: String { pick("Autobuses en directo", "Live buses", "Autobusos en directe") }
    public var metrobusPositionNote: String {
        pick("Posición GPS del autobús; se actualiza cada 20 s aproximadamente.",
             "The bus's GPS position, refreshed about every 20 s.",
             "Posició GPS de l'autobús; s'actualitza cada 20 s aproximadament.")
    }
    public var metrobusBusGone: String {
        pick("Este autobús ya no envía su posición.", "This bus no longer reports its position.", "Este autobús ja no envia la seua posició.")
    }
    public var day: String { pick("Día", "Day", "Dia") }
    public var noDeparturesThisDay: String {
        pick("No hay salidas este día", "No departures on this day", "No hi ha eixides este dia")
    }
    /// The occupancy level alone ("baja"), empty when the API has no data.
    public func occupancyLevel(_ level: String) -> String {
        switch level.uppercased() {
        case "BAJA": return pick("baja", "low", "baixa")
        case "MEDIA": return pick("media", "medium", "mitjana")
        case "ALTA": return pick("alta", "high", "alta")
        case "SIN DATOS", "": return ""
        default: return level.lowercased()
        }
    }

    /// Metrobús occupancy ("BAJA", "MEDIA", "ALTA" from the API).
    public func occupancy(_ level: String) -> String {
        let value = occupancyLevel(level)
        return pick("Ocupación \(value)", "Occupancy \(value)", "Ocupació \(value)")
    }
    public func nextStopName(_ name: String) -> String { pick("Próxima: \(name)", "Next: \(name)", "Pròxima: \(name)") }

    public var diagnostics: String { pick("Diagnóstico de red", "Network diagnostics", "Diagnòstic de xarxa") }
    public var loadedPoints: String { pick("Puntos cargados", "Loaded points", "Punts carregats") }
    public var requests: String { pick("Últimas peticiones", "Latest requests", "Últimes peticions") }

    public func lineTitle(_ line: String) -> String { pick("Línea \(line)", "Line \(line)", "Línia \(line)") }

    public func liveBuses(_ count: Int) -> String {
        count == 1
            ? pick("1 autobús en directo", "1 bus live", "1 autobús en directe")
            : pick("\(count) autobuses en directo", "\(count) buses live", "\(count) autobusos en directe")
    }

    /// EMT's "ida"/"vuelta" (outbound/return).
    public func directionLabel(_ direction: String) -> String {
        direction == "vuelta" ? pick("vuelta", "return", "tornada") : pick("ida", "outbound", "anada")
    }
}
