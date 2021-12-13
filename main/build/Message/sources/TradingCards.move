module Sender::TradingCards {
    use Std::GUID;
    use Std::Event;
    use Std::Errors;
    use Std::Vector;
    use Std::Signer;
    use Sender::NFTStandard as NFT;
    use Sender::PRNG;
    use DiemFramework::DiemAccount;
    #[test_only]
    use Std::UnitTest;

    const E_CATEGORY_LENGTH_MISMATCH: u64 = 0;

    const SUPER_RARE: u64 = 0;
    const RARE: u64 = 1;
    const NORMAL: u64 = 2;

    struct UnopenedDeck has store, drop {
        seed: u64,
        initial_owner: address,
    }

    // TODO: This should be an NFTBundle<T>
    struct OpenedDeck has store {
        deck: vector<NFT::NFT<Card>>
    }

    struct Card has store, drop {
        // name of card (or some uid for it)
        name: vector<u8>,
        // category of this card (super rare, etc)
        category: u8,
    }

    struct RegisteredCards has key {
        // indexed by card category, holds name of card
        cards_by_category: vector<vector<vector<u8>>>,
        // Distribution the different cards should have in generated decks
        deck_distribution: vector<u8>,
    }

    struct DeckMintEvent has store, drop {
        creator: address,
        creation_num: u64,
        initial_owner: address,
    }

    public(script) fun init_account(account: signer) {
        NFT::initialize<Card>(&account);
        NFT::initialize<UnopenedDeck>(&account);
    }

    public(script) fun register_card_deck(
        minter: signer,
        possible_cards: vector<u8>,
        // [category_id, ...]
        card_categories: vector<u8>,
        // [#1, 0, #2, 0, 0, #3, ...] 1 ultra rare, 0 rare, 2 slightly
        // rare, etc. We identify 256 as "there may or may not be one of
        // these" cards
        deck_distribution: vector<u8>,
    ) {
        NFT::initialize<UnopenedDeck>(&minter);
        // init to all zero
        let cards_by_category = Vector::empty();
        let i = 0;
        while (i < 256) {
            Vector::push_back(&mut cards_by_category, Vector::empty());
            i = i + 1;
        };

        i = 0;
        let possible_cards = parse_cards(possible_cards);
        let end = Vector::length(&possible_cards);
        assert!(end == Vector::length(&card_categories), Errors::invalid_argument(E_CATEGORY_LENGTH_MISMATCH));

        while (i < end) {
            let card = Vector::pop_back(&mut possible_cards);
            let category = Vector::pop_back(&mut card_categories);
            Vector::push_back(
                Vector::borrow_mut(&mut cards_by_category, (category as u64)),
                card
            );
            i = i + 1;
        };

        move_to(&minter, RegisteredCards {
            cards_by_category,
            deck_distribution,
        })
    }


    // receiver_addr should be a signer
    public(script) fun mint(minter: signer, receiver_addr: address, seed: u64, uri: vector<u8>) {
        let nft = NFT::create<UnopenedDeck>(
            &minter,
            UnopenedDeck {
                seed,
                initial_owner: receiver_addr,
            },
            uri,
        );
        let event_handle = Event::new_event_handle(&minter);
        let guid = NFT::id(&nft);
        Event::emit_event(&mut event_handle, DeckMintEvent {
            creator: GUID::creator_address(guid),
            creation_num: GUID::creation_num(guid),
            initial_owner: receiver_addr,
        });
        NFT::add(receiver_addr, nft);
        Event::destroy_handle(event_handle);
    }

    public(script) fun unpack(owner: signer, minter_addr: address, creation_num: u64)
    acquires RegisteredCards {
        let owner_addr = Signer::address_of(&owner);
        let deck_guid = GUID::create_id(minter_addr, creation_num);
        let nft = NFT::remove<UnopenedDeck>(owner_addr, &deck_guid);
        let UnopenedDeck {
            seed,
            initial_owner,
        } = NFT::destroy(nft);

        let seed =
            DiemAccount::sequence_number(initial_owner) +
            DiemAccount::sequence_number(owner_addr) +
            seed;
        select_cards(&owner, minter_addr, seed);
    }

    fun select_cards(owner: &signer, minter_addr: address, seed: u64) acquires RegisteredCards {
        let owner_addr = Signer::address_of(owner);
        let prng = PRNG::create(seed);
        let card_registration = borrow_global<RegisteredCards>(minter_addr);

        let i = 0;
        let end = Vector::length(&card_registration.deck_distribution);

        while (i < end) {
            let num_for_category = *Vector::borrow(&card_registration.deck_distribution, i);
            if (num_for_category == 255u8) {
                if (PRNG::generate(&mut prng) % 2 == 0) {
                    num_for_category = 1;
                }  else {
                    num_for_category = 0;
                };
            };
            let cards_in_category = Vector::borrow(&card_registration.cards_by_category, i);
            let num_cards_in_category = Vector::length(cards_in_category);
            if (num_cards_in_category > 0) {
                let j = 0;
                while (j < num_for_category) {
                    let selection = PRNG::generate(&mut prng) % num_cards_in_category;
                    let selected_card = *Vector::borrow(cards_in_category, selection);
                    let card = Card {
                        name: selected_card,
                        category: j
                    };
                    // TODO: auto generate URI to be itneresting
                    let nft_card = NFT::create(owner, card, x"");
                    // TODO: eventually, make this a bundle of NFTs
                    NFT::add(owner_addr, nft_card);
                    j = j + 1;
                };
            };
            i = i + 1;
        };
    }

    fun parse_cards(flat_cards: vector<u8>): vector<vector<u8>> {
        Vector::reverse(&mut flat_cards);
        let acc = Vector::empty();
        while (!Vector::is_empty(&flat_cards)) {
            let amount = Vector::pop_back(&mut flat_cards);
            let i = 0;
            let chunk = Vector::empty();
            while (i < amount) {
                Vector::push_back(&mut chunk, Vector::pop_back(&mut flat_cards));
                i = i + 1;
            };
            Vector::push_back(&mut acc, chunk);
        };

        acc
    }

    #[test_only]
    fun signer_at(index: u64): signer {
        let signers = UnitTest::create_signers_for_testing(index + 1);
        Vector::pop_back(&mut signers)
    }

    #[test]
    public(script) fun test_register() {
        let a = signer_at(0);
        let flat = vector[
            1, 0,
            2, 4, 5,
            1, 7,
            4, 1, 2, 3, 4,
        ];
        register_card_deck(
            a,
            flat,
            vector[0,1,1,2],
            vector[255, 1, 1, 2]
        );
    }



    #[test]
    public(script) fun test_mint() {
        let b = signer_at(1);
        init_account(b);
        let a = signer_at(0);
        let flat = vector[
            1, 0,
            2, 4, 5,
            1, 7,
            4, 1, 2, 3, 4,
        ];
        register_card_deck(
            a,
            flat,
            vector[0,1,1,2],
            vector[255, 1, 1, 2]
        );
        let a = signer_at(0);
        mint(a, Signer::address_of(&signer_at(1)), 42, b"Hello");
    }

    #[test]
    public(script) fun test_unpack() acquires RegisteredCards {
        let b = signer_at(1);
        init_account(b);
        let a = signer_at(0);
        let flat = vector[
            1, 0,
            2, 4, 5,
            1, 7,
            4, 1, 2, 3, 4,
        ];
        register_card_deck(
            a,
            flat,
            vector[0,1,1,2],
            vector[255, 1, 1, 2]
        );
        let a = signer_at(0);
        let b = signer_at(1);
        mint(a, Signer::address_of(&b), 42, b"Hello");
        unpack(b, Signer::address_of(&signer_at(0)), 0);
    }

    #[test]
    fun test_parse_cards() {
        let flat = vector[
            1, 0,
            2, 4, 5,
            1, 7,
            4, 1, 2, 3, 4,
        ];

        assert!(parse_cards(flat) == vector[
            vector[0],
            vector[4,5],
            vector[7],
            vector[1,2,3,4],
        ], 0);
    }
}
