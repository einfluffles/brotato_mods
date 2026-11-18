# brotato:trade

Give items and weapons to other players in the co-op shop of
[Brotato](https://store.steampowered.com/app/1942280/Brotato/), and the item of a crate you open
after a wave.

**Status:** new. The rules, the hand-over and the shop screen are covered by headless tests; it
has not been played in the real game yet (see *Open*).

Mod id: `einfluffles-BrotatoTrade` · source: [`src/einfluffles-BrotatoTrade`](src/einfluffles-BrotatoTrade) · license: [MIT](../../LICENSE)

## Playing

In the co-op shop, press *accept* on a weapon or item of your own, as you would to combine or
recycle a weapon. The popup has a **Trade** button above *Cancel*. It opens the list of players
who can take the item ("Player 2" in that player's colour, with its character); pick one and the
item is theirs. *Cancel* (button or key) leads back from the list.

A trade is a gift: nothing is paid and the receiver is not asked.

- **Trade only shows when somebody can take the item**, and the list only names those players.
  An item nobody can take has no popup buttons, as in the game.
- **Items:** the item's limit holds. A player who has a unique item is not offered another, a
  limited item (e.g. 3 of a kind) goes up to its limit. What the receiver's shop offers right now
  (locked or not) counts too, as when the game rolls the shop: a player whose shop offers the
  unique item cannot be given one on top and then buy it as well.
- **Weapons** follow the game's rules for buying one: it needs a free slot, or the receiver
  combines it with the same weapon into the next tier ("Player 2 (Combine)" in the list). With
  several weapons to combine with, a cursed one is used first. A receiver that takes no melee /
  ranged weapons or is limited to a tier is not offered; a giver whose weapons are locked cannot
  give any.
- **Not tradable:** characters, items the game never offers in a shop or crate (builder turret,
  tumor, hatched eggs, used-up leftovers) and items with an effect that giving them away does not
  undo, which passing them back and forth would farm: Axolotl (its swap is done), the Leaps
  (Evolution is multiplied anew), Handcuffs and Shackles (the cap is set anew), Bait, Lure,
  Peacock, Celery Tea, Scarf, Weird Ghost and Hourglass (their next-wave effect is used up when
  the wave starts, the receiver would get it again) and Dangerous Bunny (its free rerolls).
- The receiver gets the item as it is (cursed stays cursed, a weapon keeps its tracked values).
  Buying effects do not run: no stat-gain triggers, no mutation on equip, no free reroll in the
  same shop.

### Crates

When you open a crate after a wave, the crate panel has a **Trade** button below *Take*. It
lists the other players, with *Cancel*; pick one and the crate's item is theirs instead of yours.
Your panel goes on to your next crate or level-up, as after *Take*.

- **Players without room are listed but cannot be picked** (greyed out, the cursor skips them):
  the item's limit (a unique item they own, counting their locked shop items as the game does for
  crates), or for a weapon the rules above plus what *Take* checks (a free slot, else a weapon to
  combine with: "Player 2 (Combine)"). With nobody to take it, *Trade* cannot be pressed.
- Your own slots do not matter: with no room for a crate weapon you cannot *Take* it, but you can
  trade it.
- The receiver takes the item the way *Take* does (the game's own code, with the receiver as the
  one who takes): stat-gain effects and mutation on equip run for the receiver, a weapon without a
  free slot is combined. A meca item needs its effect picked first, as for *Take*.
- *Cancel* (button or key) leads back to *Take*, *Trade*, *Recycle* and *Ban*.

### With brotato:together

Works online with [brotato:together](../brotato-together). The host needs both mods; a client
needs brotato:trade to trade itself (without it, it still sees what the others trade). A client
whose host has no brotato:trade gets no Trade button. brotato:together must be the version with
intents for other mods (protocol 21 for the shop, protocol 30 for crates).

### Buying for another player

Every item the shop offers you has a **Trade** button right of its price (move right from the
item, or click it online). It opens the item's popup with every other player and *Cancel*; pick
one and you buy the item for them: you pay, they get it.

- **Players without room are listed but cannot be picked** (greyed out, the cursor skips them),
  by the game's own rules for a buy: for a weapon what the shop asks before it sells one to that
  player (tier, melee / ranged, a free slot, else a weapon to combine with: "Player 2
  (Combine)"); for an item its limit (a unique item they own, counting what their own shop
  offers, as for a trade). With nobody to buy for, *Trade* cannot be pressed.
- **Your own slots do not matter**: with 6/6 weapons you can still buy a weapon for a player
  with room, and you keep all of yours. Nothing of yours changes but your gold.
- **As a buy**: the same price (yours, with your coupons), the same delay between two buys, the
  item leaves your shop (a locked one too, unlocked as by a buy) and your gold shakes when it
  is not enough. The receiver gets the item the way a buy gives it (the game's `buy_item` /
  `buy_weapon` for the receiver): stat-gain effects, mutation on equip, duplication, a weapon
  combined without a free slot, free rerolls an item gives. Meca items (an effect to pick on the
  card) have no Trade button.
- Online the press leaves as a shop intent `trade.buy` (the shop item's place, its item's id, the
  receiver) and the host buys with the same code; it needs a host with this version of
  brotato:trade.

## How it works

- **One step, on the game that owns the run** (`trade/transfer.gd`). Everything is checked first
  (`trade/rules.gd`), then the object leaves the giver's list and enters the receiver's in the
  same call, through the game's own `RunData` functions (so stats, sets and caches follow). Each
  step is counted before the next: an object that did not leave is not added anywhere, one that
  did not arrive goes back to the giver. No frame, save or network state sees it in both lists
  or in none.
- **Online, only the host changes the run.** A client's Trade press leaves as a shop intent
  (`trade.item` / `trade.weapon`: the object's place in the giver's list, its id, the receiver).
  The host checks sender, place, id and the rules again and applies it with the same code as a
  local trade; the result reaches every client with the host's next shop state. A trade skips the
  panel revision the game's own presses carry: two quick trades of the same item both count
  (with the revision, the second was dropped as stale until the host's answer had arrived).
- **Crates** (`extensions/ui/upgrades_ui.gd`): the game's Take runs with the receiver as the one
  who takes. The container's press (without its check of the giver's weapon slots) emits its
  `item_take_button_pressed`; for that press the option the panel processes names the receiver,
  so `UpgradesUI._on_take_button_pressed` and `main.on_item_box_take_button_pressed` give the item
  to the receiver and move the giver's panel on. The receiver's stats, gear and crate weapons are
  shown again, its cursor kept in place. Online a client's press leaves as a level-up intent
  (`trade.crate`: the crate item's id, the receiver) with the panel's revision; the host checks it
  and applies it with the same code.
- **UI:** script extensions of the game's `CoopItemPopup` (the button and the list, built from the
  popup's own Cancel button), `CoopShop` (who can take what, both panels afterwards),
  `CoopUpgradesUIPlayerContainer` (the crate panel's Trade button and list, built from its Take
  button) and `UpgradesUI` (the crate hand-over).
- **Buying for another player** (`extensions/ui/coop_shop.gd`): the checks of the shop's buy
  press, the receiver's room by the game's rules, then the shop items container's own
  `shop_item_bought` signal: `BaseShop.on_shop_item_bought` runs for the giver (price, coupons,
  the offer), only `buy_item` / `buy_weapon` go to the receiver; then the slot goes as after a
  buy, and the receiver's part (stats, prices, rerolls) and its cursor follow. The Trade buttons
  on the shop items are built from the item's own button script and font.

## Tests

`tests/einfluffles-TradeTests` is a dev-only mod run by `tools/check.sh mods/brotato-trade`: the
rules and the hand-over on `RunData` (limits, the same object in several lists, effects moving
with the item, combining with the cursed weapon, nothing appearing or vanishing), the real co-op
shop driven with each player's buttons (popup, list, cancel, both panels and every cursor after a
trade), buying for another player (`buy_tests.gd`, run by the shop suite: a giver with 6/6
weapons, a receiver without room, price, lock, slot and offers as for a buy, not enough gold),
the crate panels on the real battle scene (the button, the list with a player who has no
room, cancel, an item and a weapon traded by a giver without a free slot, the receiver's cursor),
and processes that also load brotato:together (a remote player's request applied once on the
host, a client's press only sending it, the host's state bringing the result; the same for a
crate trade; a client's buy for another with the mouse and with the buttons).

## Open

- Not played in the real game yet: the look of the buttons (the character icon on a player
  button, the popup's height with four players, the crate panel's list with four players and
  its crate weapons below) is untested, the headless tests have no renderer.
- Online, a crate trade is tested on the host and on a client's side of the panels set up by
  hand, not between two running games.
- The shop items' Trade button is untested to the eye: it narrows the item's card (its
  description and price) in the co-op panels, most of all with four players.
- No Workshop item or preview image yet.
- The button text "Trade" is English in every language.
- Online, a cursor on the Trade buttons is only shown to players who have the mod too.
