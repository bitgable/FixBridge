import Combine
import CoreLocation
import Foundation

/// Owns target input and saved locations. Input, terrain estimates and saved records have separate lifetimes.
@MainActor
final class TargetLocationViewModel: ObservableObject {
    struct FocusRequest: Equatable {
        let id = UUID()
        let field: LocationInput.Field
    }
    @Published private(set) var fieldErrors: [LocationInput.Field: String] = [:]
    @Published private(set) var focusRequest: FocusRequest?

    enum AltitudeLookupStatus {
        case idle, loading, estimated
    }

    private static let maximumNameBytes = 512

    @Published var latitude = "" {
        didSet {
            if latitude != oldValue {
                fieldErrors[.latitude] = nil
                cancelAltitudeLookup()
                selectedPointID = nil
            }
        }
    }
    @Published var longitude = "" {
        didSet {
            if longitude != oldValue {
                fieldErrors[.longitude] = nil
                cancelAltitudeLookup()
                selectedPointID = nil
            }
        }
    }
    @Published var altitude = "" {
        didSet {
            if altitude != oldValue {
                fieldErrors[.altitude] = nil
                cancelAltitudeLookup()
                selectedPointID = nil
            }
        }
    }
    @Published private(set) var altitudeLookupStatus = AltitudeLookupStatus.idle

    @Published private(set) var savedPoints: [SavedLocation] = []
    @Published private(set) var selectedPointID: UUID?

    var selectedPointName: String? {
        savedPoints.first { $0.id == selectedPointID }?.name
    }

    var hasUnsavedTarget: Bool {
        selectedPointID == nil
            && [latitude, longitude, altitude].contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private var savedLocationsReadable = true
    private var altitudeLookup: Task<Void, Never>?
    private let lookupElevation: (CLLocationCoordinate2D) async -> Double?

    init(
        defaults: UserDefaults = .standard,
        lookupElevation: @escaping (CLLocationCoordinate2D) async -> Double? = { await TerrainElevation.lookup($0) }
    ) {
        self.defaults = defaults
        self.lookupElevation = lookupElevation
        do {
            savedPoints = try SavedLocationStore.load(defaults: defaults)
        } catch {
            savedLocationsReadable = false
            self.error = SavedLocationStore.unreadable().localizedDescription
        }
    }

    // Apply transmitted values without starting a terrain request or overwriting a saved record.
    func applyLocationFix(_ fix: LocationFix) {
        clearFieldValidation()
        cancelAltitudeLookup()
        let locale = Locale(identifier: "en_US_POSIX")
        latitude = String(format: "%.7f", locale: locale, fix.latitude)
        longitude = String(format: "%.7f", locale: locale, fix.longitude)
        altitude = String(format: "%.2f", locale: locale, fix.altitude)
        selectedPointID = nil
        error = nil
    }

    func validateField(_ field: LocationInput.Field, required: Bool = false) {
        let text: String =
            switch field {
            case .latitude: latitude
            case .longitude: longitude
            case .altitude: altitude
            }
        fieldErrors[field] = LocationInput.validationMessage(for: field, text: text, required: required)
    }

    @discardableResult
    func validateForSubmission() -> Bool {
        for field in LocationInput.Field.allCases { validateField(field, required: true) }
        guard let first = LocationInput.Field.allCases.first(where: { fieldErrors[$0] != nil }) else { return true }
        focusRequest = FocusRequest(field: first)
        return false
    }

    private func clearFieldValidation() {
        fieldErrors = [:]
        focusRequest = nil
    }

    var input: LocationInput { LocationInput(latitude: latitude, longitude: longitude, altitude: altitude) }

    func makeFix() throws -> LocationFix { try input.makeFix() }

    var mapCoordinate: CLLocationCoordinate2D? {
        input.decimalCoordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    func applyMapCoordinate(_ point: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(point) else { return }
        clearFieldValidation()
        cancelAltitudeLookup()
        selectedPointID = nil
        let current = mapCoordinate
        if point.latitude != current?.latitude || point.longitude != current?.longitude {
            latitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), point.latitude)
            longitude = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), point.longitude)
        }
        error = nil
        altitudeLookupStatus = .loading
        let lookupElevation = self.lookupElevation
        altitudeLookup = Task { [weak self] in
            let estimate = await lookupElevation(point)
            guard !Task.isCancelled, let self else { return }
            altitudeLookup = nil
            let meters = estimate ?? 100
            if Double(altitude) != meters {
                altitude = estimate.map { String($0) } ?? "100"
                selectedPointID = nil
            }
            altitudeLookupStatus = estimate == nil ? .idle : .estimated
        }
    }

    func cancelAltitudeLookup() {
        altitudeLookup?.cancel()
        altitudeLookup = nil
        if altitudeLookupStatus != .idle { altitudeLookupStatus = .idle }
    }

    func preparePoint() throws -> LocationDraft {
        guard savedLocationsReadable else { throw SavedLocationStore.unreadable() }
        let point = try LocationInput(latitude: latitude, longitude: longitude, altitude: altitude).makeFix()
        try LocationFix.validateTarget(latitude: point.latitude, longitude: point.longitude, altitude: point.altitude)
        return LocationDraft(id: UUID(), latitude: point.latitude, longitude: point.longitude, altitude: point.altitude)
    }

    func updatePoint(
        _ original: LocationDraft, named name: String, latitude: String, longitude: String, altitude: String
    )
        throws
    {
        guard let saved = savedPoints.first(where: { $0.id == original.id }),
            original.name == saved.name, original.latitude == saved.latitude,
            original.longitude == saved.longitude, original.altitude == saved.altitude
        else { throw FixBridgeError("The saved location changed or no longer exists. Reopen it to edit.") }
        let point = try LocationInput(latitude: latitude, longitude: longitude, altitude: altitude).makeFix()
        try savePoint(
            LocationDraft(
                id: original.id, name: original.name, latitude: point.latitude,
                longitude: point.longitude, altitude: point.altitude), named: name)
    }

    func savePoint(_ point: LocationDraft, named text: String) throws {
        guard text.utf8.prefix(Self.maximumNameBytes + 1).count <= Self.maximumNameBytes else {
            throw FixBridgeError("Use a shorter location name.")
        }
        try LocationFix.validateTarget(latitude: point.latitude, longitude: point.longitude, altitude: point.altitude)
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FixBridgeError("Enter a location name.") }
        guard
            !savedPoints.contains(where: {
                $0.id != point.id && $0.name.caseInsensitiveCompare(name) == .orderedSame
            })
        else {
            throw FixBridgeError("A location with that name already exists.")
        }
        // A new draft must insert; an editing draft must still refer to a saved item.
        let isEditing = point.name != nil
        guard savedPoints.contains(where: { $0.id == point.id }) == isEditing else {
            throw FixBridgeError("The saved location changed or no longer exists. Reopen it to edit.")
        }
        let saved = SavedLocation(
            id: point.id, name: name, latitude: point.latitude,
            longitude: point.longitude, altitude: point.altitude)
        if let index = savedPoints.firstIndex(where: { $0.id == saved.id }) {
            var points = savedPoints
            points[index] = saved
            try storePoints(points)
            if selectedPointID == saved.id { loadPoint(saved) }
        } else {
            try storePoints(savedPoints + [saved])
            loadPoint(saved)
        }
    }

    func loadPoint(_ point: SavedLocation) {
        guard let point = savedPoints.first(where: { $0.id == point.id }) else {
            error = String(localized: "The saved location changed or no longer exists. Reopen it to edit.")
            return
        }
        cancelAltitudeLookup()
        clearFieldValidation()
        latitude = String(point.latitude)
        longitude = String(point.longitude)
        altitude = String(point.altitude)
        selectedPointID = point.id
        error = nil
    }

    func deleteDraft(_ draft: LocationDraft) throws {
        guard let saved = savedPoints.first(where: { $0.id == draft.id }),
            saved.name == draft.name, saved.latitude == draft.latitude,
            saved.longitude == draft.longitude, saved.altitude == draft.altitude
        else { throw FixBridgeError("The saved location changed or no longer exists. Reopen it to edit.") }
        try removePoint(saved)
    }

    func removePoint(_ point: SavedLocation) throws {
        do {
            guard savedPoints.contains(point) else {
                throw FixBridgeError("The saved location changed or no longer exists. Reopen it to edit.")
            }
            try storePoints(savedPoints.filter { $0.id != point.id })
            if selectedPointID == point.id { selectedPointID = nil }
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    private func storePoints(_ points: [SavedLocation]) throws {
        guard savedLocationsReadable else { throw SavedLocationStore.unreadable() }
        guard try SavedLocationStore.load(defaults: defaults) == savedPoints else {
            throw FixBridgeError(
                "Saved locations changed in another window or app instance. Quit and reopen FixBridge before saving.")
        }
        try SavedLocationStore.save(points, defaults: defaults)
        savedPoints = points
        error = nil
    }
}
