Then /^I start Electrum through the GNOME menu$/ do
  step "I start \"Electrum Bitcoin Wallet\" via GNOME Activities Overview"
end

When /^a bitcoin wallet is (|not )present$/ do |existing|
  wallet = "/home/#{LIVE_USER}/.electrum/wallets/default_wallet"
  case existing
  when ""
    step "the file \"#{wallet}\" exists after at most 30 seconds"
  when "not "
    step "the file \"#{wallet}\" does not exist"
  else
    raise "Unknown value specified for #{existing}"
  end
end

When /^I create a new bitcoin wallet$/ do
  @screen.wait("ElectrumNoWallet.png", 10)
  @screen.wait_and_click("ElectrumNextButton.png", 10)
  @screen.wait("ElectrumCreateNewSeed.png", 10)
  @screen.wait_and_click("ElectrumNextButton.png", 10)
  @screen.wait("ElectrumWalletGenerationSeed.png", 15)
  @screen.wait_and_click("ElectrumWalletSeedTextbox.png", 15)
  @screen.type('a', Sikuli::KeyModifier.CTRL) # select wallet seed
  @screen.type('c', Sikuli::KeyModifier.CTRL) # copy seed to clipboard
  seed = $vm.get_clipboard
  @screen.wait_and_click("ElectrumNextButton.png", 15)
  @screen.wait("ElectrumSeedVerificationPrompt.png", 15)
  @screen.wait_and_click("ElectrumWalletSeedTextbox.png", 15)
  @screen.type(seed) # Confirm seed
  @screen.wait_and_click("ElectrumNextButton.png", 10)
  @screen.wait("ElectrumEncryptWallet.png", 10)
  @screen.type(Sikuli::Key.TAB)          # focus first password field
  @screen.type("asdf" + Sikuli::Key.TAB) # set password
  @screen.type("asdf" + Sikuli::Key.TAB) # confirm password
  @screen.wait_and_click("ElectrumNextButton.png", 10)
  @screen.wait("ElectrumPreferencesButton.png", 30)
end

Then /^I see a warning that Electrum is not persistent$/ do
  @screen.wait('GnomeQuestionDialogIcon.png', 30)
end

Then /^I am prompted to configure Electrum$/ do
  @screen.wait("ElectrumNoWallet.png", 60)
end

Then /^I see the main Electrum client window$/ do
  @screen.wait('ElectrumPreferencesButton.png', 20)
end

Then /^Electrum successfully connects to the network$/ do
  @screen.wait('ElectrumStatus.png', 180)
end
