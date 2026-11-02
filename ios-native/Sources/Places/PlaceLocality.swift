import Foundation
import MapKit

/// The city Apple Maps names around one place unit, with its country (REBUILD_ROADMAP.md L1).
/// Immich names each photo after the nearest named place, which in a city is often a neighborhood;
/// the locality is the city that neighborhood lies in, as the phone's own Photos would name it.
struct PlaceLocality: Codable, Hashable, Sendable {
    /// Nil where Apple Maps names no city: at sea, or far from any town.
    let city: String?
    /// ISO 3166-1 alpha-2, as Apple Maps gives it.
    let countryCode: String?

    /// What is found where Apple Maps knows no place at all.
    static let nowhere = PlaceLocality(city: nil, countryCode: nil)
}

/// The localities resolved so far, by unit key, in the language they were resolved in.
struct PlaceLocalities: Codable, Equatable, Sendable {
    var language: String
    var units: [String: PlaceLocality] = [:]

    subscript(unit: String) -> PlaceLocality? { units[unit] }
}

/// Why a locality couldn't be found this time. Both are worth asking again later.
enum PlaceGeocodingFailure: Error, Sendable {
    /// Apple Maps asked the app to slow down.
    case throttled
    /// No answer: offline, or the service failed.
    case unavailable
}

/// Finds the locality at a point. Apple Maps on the phone; a fake in tests.
protocol PlaceGeocoder: Sendable {
    @MainActor func locality(latitude: Double, longitude: Double, language: String) async throws(PlaceGeocodingFailure) -> PlaceLocality
}

/// Apple Maps' reverse geocoding, as the phone's Photos uses it. Only a unit's one representative
/// photo location is sent, and only once: the answer is kept on the phone.
struct AppleMapsGeocoder: PlaceGeocoder {
    @MainActor func locality(latitude: Double, longitude: Double, language: String) async throws(PlaceGeocodingFailure) -> PlaceLocality {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) else { return .nowhere }
        request.preferredLocale = Locale(identifier: language)
        do {
            let names = try await request.mapItems.first?.addressRepresentations
            return PlaceLocality(city: names?.cityName, countryCode: names?.region?.identifier)
        } catch let error as MKError {
            switch error.code {
            case .loadingThrottled: throw .throttled
            case .placemarkNotFound: return .nowhere
            default: throw .unavailable
            }
        } catch {
            throw .unavailable
        }
    }
}

/// The continents countries lie on, by ISO code, from GeoNames' country table (countryInfo.txt).
enum Continent: String, CaseIterable, Sendable {
    case africa = "AF", antarctica = "AN", asia = "AS", europe = "EU", northAmerica = "NA", oceania = "OC", southAmerica = "SA"

    var name: String {
        switch self {
        case .africa: "Africa"
        case .antarctica: "Antarctica"
        case .asia: "Asia"
        case .europe: "Europe"
        case .northAmerica: "North America"
        case .oceania: "Oceania"
        case .southAmerica: "South America"
        }
    }

    static func of(countryCode: String) -> Continent? { table[countryCode.uppercased()] }

    private static let table: [String: Continent] = {
        var table: [String: Continent] = [:]
        for pair in pairs.split(separator: " ") {
            let parts = pair.split(separator: ":")
            if parts.count == 2, let continent = Continent(rawValue: String(parts[1])) { table[String(parts[0])] = continent }
        }
        return table
    }()

    private static let pairs = """
    AD:EU AE:AS AF:AS AG:NA AI:NA AL:EU AM:AS AO:AF AQ:AN AR:SA AS:OC AT:EU AU:OC AW:NA AX:EU AZ:AS BA:EU BB:NA BD:AS BE:EU BF:AF BG:EU BH:AS BI:AF \
    BJ:AF BL:NA BM:NA BN:AS BO:SA BQ:NA BR:SA BS:NA BT:AS BV:AN BW:AF BY:EU BZ:NA CA:NA CC:AS CD:AF CF:AF CG:AF CH:EU CI:AF CK:OC CL:SA CM:AF CN:AS \
    CO:SA CR:NA CU:NA CV:AF CW:NA CX:OC CY:EU CZ:EU DE:EU DJ:AF DK:EU DM:NA DO:NA DZ:AF EC:SA EE:EU EG:AF EH:AF ER:AF ES:EU ET:AF FI:EU FJ:OC FK:SA \
    FM:OC FO:EU FR:EU GA:AF GB:EU GD:NA GE:AS GF:SA GG:EU GH:AF GI:EU GL:NA GM:AF GN:AF GP:NA GQ:AF GR:EU GS:AN GT:NA GU:OC GW:AF GY:SA HK:AS HM:AN \
    HN:NA HR:EU HT:NA HU:EU ID:AS IE:EU IL:AS IM:EU IN:AS IO:AS IQ:AS IR:AS IS:EU IT:EU JE:EU JM:NA JO:AS JP:AS KE:AF KG:AS KH:AS KI:OC KM:AF KN:NA \
    KP:AS KR:AS XK:EU KW:AS KY:NA KZ:AS LA:AS LB:AS LC:NA LI:EU LK:AS LR:AF LS:AF LT:EU LU:EU LV:EU LY:AF MA:AF MC:EU MD:EU ME:EU MF:NA MG:AF MH:OC \
    MK:EU ML:AF MM:AS MN:AS MO:AS MP:OC MQ:NA MR:AF MS:NA MT:EU MU:AF MV:AS MW:AF MX:NA MY:AS MZ:AF NA:AF NC:OC NE:AF NF:OC NG:AF NI:NA NL:EU NO:EU \
    NP:AS NR:OC NU:OC NZ:OC OM:AS PA:NA PE:SA PF:OC PG:OC PH:AS PK:AS PL:EU PM:NA PN:OC PR:NA PS:AS PT:EU PW:OC PY:SA QA:AS RE:AF RO:EU RS:EU RU:EU \
    RW:AF SA:AS SB:OC SC:AF SD:AF SS:AF SE:EU SG:AS SH:AF SI:EU SJ:EU SK:EU SL:AF SM:EU SN:AF SO:AF SR:SA ST:AF SV:NA SX:NA SY:AS SZ:AF TC:NA TD:AF \
    TF:AN TG:AF TH:AS TJ:AS TK:OC TL:OC TM:AS TN:AF TO:OC TR:AS TT:NA TV:OC TW:AS TZ:AF UA:EU UG:AF UM:OC US:NA UY:SA UZ:AS VA:EU VC:NA VE:SA VG:NA \
    VI:NA VN:AS VU:OC WF:OC WS:OC YE:AS YT:AF ZA:AF ZM:AF ZW:AF
    """
}
