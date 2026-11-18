// SPEC-004: read-only lookup shapes for the New Complaint form. All of
// these are ERP master data — the app never creates/edits them, only
// displays them for selection (per the facility-app-scope-boundary rule).

class BuildingLookup {
  const BuildingLookup({required this.id, required this.name});

  final String id;
  final String name;

  factory BuildingLookup.fromJson(Map<String, dynamic> json) => BuildingLookup(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}

class UnitLookup {
  const UnitLookup({required this.id, required this.unitNumber});

  final String id;
  final String unitNumber;

  factory UnitLookup.fromJson(Map<String, dynamic> json) => UnitLookup(
        id: json['id'] as String,
        unitNumber: json['unit_number'] as String,
      );
}

class ComplaintSubcategoryLookup {
  const ComplaintSubcategoryLookup({required this.id, required this.name});

  final String id;
  final String name;

  factory ComplaintSubcategoryLookup.fromJson(Map<String, dynamic> json) =>
      ComplaintSubcategoryLookup(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}

class ComplaintCategoryLookup {
  const ComplaintCategoryLookup({
    required this.id,
    required this.name,
    required this.subcategories,
  });

  final String id;
  final String name;
  final List<ComplaintSubcategoryLookup> subcategories;

  factory ComplaintCategoryLookup.fromJson(Map<String, dynamic> json) =>
      ComplaintCategoryLookup(
        id: json['id'] as String,
        name: json['name'] as String,
        subcategories: (json['subcategories'] as List<dynamic>? ?? [])
            .map((e) => ComplaintSubcategoryLookup.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// A tenant or owner record tied to a selected unit (from
/// `related-parties`), or a search result (from the `parties` lookup).
class PartyLookup {
  const PartyLookup({required this.id, required this.name, this.subtitle});

  final String id;
  final String name;
  final String? subtitle;

  factory PartyLookup.fromTenantJson(Map<String, dynamic> json) => PartyLookup(
        id: json['id'] as String,
        name: json['full_name'] as String,
        subtitle: json['phone'] as String?,
      );

  factory PartyLookup.fromOwnerJson(Map<String, dynamic> json) => PartyLookup(
        id: json['id'] as String,
        name: json['full_name'] as String,
        subtitle: json['phone_number'] as String?,
      );
}
