# Apple returns the storefront ID alone or with qualifiers, e.g. "143462-1,29".
(
  select(length == 1)
  | .[0].account.storefront
  | strings
  | capture("\\A(?<id>[1-9][0-9]*)(?:[-,]|\\z)").id
) // error("Expected a numeric App Store storefront ID")
