package main

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/juju/persistent-cookiejar"
	"github.com/majd/ipatool/v2/pkg/appstore"
	storehttp "github.com/majd/ipatool/v2/pkg/http"
	"github.com/majd/ipatool/v2/pkg/util/machine"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
	"golang.org/x/term"
)

var (
	errCancelled   = errors.New("verification cancelled")
	errInvalidCode = errors.New("verification code must contain six digits")
)

const provisioningKey = "anisette-v4"

// sessionState is the SDK's in-memory keychain for one invocation.
type sessionState map[string][]byte

func (s sessionState) Get(key string) ([]byte, error) {
	data, ok := s[key]
	if !ok {
		return nil, os.ErrNotExist
	}
	return data, nil
}

func (s sessionState) Set(key string, data []byte) error {
	s[key] = append([]byte(nil), data...)
	return nil
}

func (s sessionState) Remove(key string) error {
	delete(s, key)
	return nil
}

type storeContext struct {
	GUID         string          `json:"guid"`
	Account      savedAccount    `json:"account"`
	Cookies      json.RawMessage `json:"cookies"`
	Provisioning []byte          `json:"provisioning"`
}

type savedAccount struct {
	DSID          string `json:"dsid"`
	Storefront    string `json:"storefront"`
	Pod           string `json:"pod,omitempty"`
	PasswordToken string `json:"passwordToken"`
}

func authenticate(login func(appstore.LoginInput) (appstore.LoginOutput, error), input appstore.LoginInput, code func() (string, error)) (appstore.LoginOutput, error) {
	result, err := login(input)
	if !errors.Is(err, appstore.ErrAuthCodeRequired) {
		return result, err
	}
	input.AuthCode, err = code()
	if err != nil {
		return result, err
	}
	if input.AuthCode == "" {
		return result, errCancelled
	}
	result, err = login(input)
	if err != nil && err.Error() == "2FA code must contain exactly six digits" {
		return result, errInvalidCode
	}
	return result, err
}

func validateAccount(account appstore.Account) error {
	id, err := strconv.ParseUint(account.DirectoryServicesID, 10, 64)
	if err != nil || id == 0 || account.StoreFront == "" || account.PasswordToken == "" || (account.Pod != "" && strings.Trim(account.Pod, "0123456789") != "") {
		return errors.New("invalid Store account context")
	}
	return nil
}

type sessionMachine struct {
	machine.Machine
	address string
}

// restoredJar defers cookie saves so they can be written with device registration.
type restoredJar struct{ *cookiejar.Jar }

func (restoredJar) Save() error { return nil }

func (m sessionMachine) MacAddress() (string, error) { return m.address, nil }

type restoredSession struct {
	Store   appstore.AppStore
	Account appstore.Account
	jar     *cookiejar.Jar
	state   sessionState
	address string
}

// save writes the session to private staging for publication after success.
func (s *restoredSession) save(work string) error {
	hardware, err := net.ParseMAC(s.address)
	if err != nil || len(hardware) != 6 {
		return errors.New("invalid Store device identifier")
	}
	if err := validateAccount(s.Account); err != nil {
		return err
	}
	provisioning := s.state[provisioningKey]
	if len(provisioning) == 0 {
		return errors.New("Store provisioning is missing")
	}
	cookies, err := s.jar.MarshalJSON()
	if err != nil {
		return errors.New("could not serialize Store cookies")
	}
	saved := storeContext{
		GUID: strings.ToUpper(hex.EncodeToString(hardware)),
		Account: savedAccount{
			DSID:          s.Account.DirectoryServicesID,
			Storefront:    s.Account.StoreFront,
			Pod:           s.Account.Pod,
			PasswordToken: s.Account.PasswordToken,
		},
		Cookies:      cookies,
		Provisioning: provisioning,
	}
	data, err := json.Marshal(saved)
	if err != nil || os.WriteFile(filepath.Join(work, "context.json"), data, 0600) != nil {
		return errors.New("could not write the staged Store context")
	}
	return nil
}

func restoreStore(work string) (*restoredSession, error) {
	data, err := os.ReadFile(filepath.Join(work, "context.json"))
	if err != nil {
		return nil, errors.New("could not read Store context")
	}
	var saved storeContext
	if err := json.Unmarshal(data, &saved); err != nil {
		return nil, errors.New("invalid Store context")
	}
	hardware, err := hex.DecodeString(saved.GUID)
	if err != nil || len(hardware) != 6 {
		return nil, errors.New("invalid Store device identifier")
	}
	account := appstore.Account{
		DirectoryServicesID: saved.Account.DSID,
		StoreFront:          saved.Account.Storefront,
		Pod:                 saved.Account.Pod,
		PasswordToken:       saved.Account.PasswordToken,
	}
	if err := validateAccount(account); err != nil {
		return nil, err
	}
	if len(saved.Provisioning) == 0 {
		return nil, errors.New("Store provisioning is missing")
	}
	jar, err := cookiejar.New(&cookiejar.Options{Filename: filepath.Join(work, "cookies.json")})
	if err != nil {
		return nil, errors.New("could not restore Store cookies")
	}
	osInfo := operatingsystem.New()
	device := sessionMachine{Machine: machine.New(machine.Args{OS: osInfo}), address: net.HardwareAddr(hardware).String()}
	state := sessionState{provisioningKey: saved.Provisioning}
	store := appstore.NewAppStore(appstore.Args{
		Keychain:        state,
		CookieJar:       restoredJar{jar},
		OperatingSystem: osInfo,
		Machine:         device,
	})
	return &restoredSession{
		Store:   store,
		Account: account,
		jar:     jar,
		state:   state,
		address: device.address,
	}, nil
}

func readHidden(prompt string) (string, error) {
	fmt.Fprint(os.Stderr, prompt)
	value, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	return string(value), err
}

func login(work string) error {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return errors.New("run this command in an interactive terminal")
	}
	fmt.Fprint(os.Stderr, "Apple account: ")
	reader := bufio.NewReader(os.Stdin)
	email, err := reader.ReadString('\n')
	if err != nil {
		return errors.New("could not read account")
	}
	email = strings.TrimSpace(email)
	password, err := readHidden("Apple password: ")
	if err != nil || email == "" || password == "" {
		return errors.New("could not read account credentials")
	}
	jar, err := cookiejar.New(&cookiejar.Options{NoPersist: true})
	if err != nil {
		return errors.New("could not initialize Store session")
	}
	osInfo := operatingsystem.New()
	device := machine.New(machine.Args{OS: osInfo})
	// Keep ipatool's account record and password in memory.
	state := sessionState{}
	store := appstore.NewAppStore(appstore.Args{
		Keychain:        state,
		CookieJar:       jar,
		OperatingSystem: osInfo,
		Machine:         device,
	})
	fmt.Fprintln(os.Stderr, "Contacting the App Store (the first run may take a few minutes)…")
	result, err := authenticate(store.Login, appstore.LoginInput{Email: email, Password: password}, func() (string, error) {
		value, readErr := readHidden("Verification code: ")
		if readErr != nil || value == "" {
			return "", errCancelled
		}
		return value, nil
	})
	password = ""
	if err != nil {
		if errors.Is(err, appstore.ErrAuthCodeRequired) {
			return errors.New("Store still requires a verification code")
		}
		if errors.Is(err, errInvalidCode) || errors.Is(err, errCancelled) {
			return err
		}
		var response *storehttp.UnexpectedResponseError
		if errors.As(err, &response) {
			return fmt.Errorf("Store sign-in failed (HTTP %d)", response.StatusCode)
		}
		// Underlying errors can include the account name, URLs or server response data.
		for _, stage := range []string{"prepare Apple authentication", "get Store authentication bag",
			"complete Apple Store provisioning", "prepare Store AMD proof", "generate Apple Store provisioning kbsync",
			"get Store machine identity", "2FA verification", "sign-in request"} {
			if strings.HasPrefix(err.Error(), stage+":") || strings.HasPrefix(err.Error(), stage+" ") {
				return fmt.Errorf("Store sign-in failed during %s", stage)
			}
		}
		return errors.New("Store sign-in failed before a usable Store session was returned")
	}
	address, err := device.MacAddress()
	if err != nil {
		return errors.New("could not determine Store device identifier")
	}
	session := restoredSession{Account: result.Account, jar: jar, state: state, address: address}
	return session.save(work)
}

func run(args []string) error {
	var app appstore.App
	switch {
	case len(args) == 2 && args[0] == "login":
		return login(args[1])
	case len(args) == 3 && args[0] == "download-stream":
	case len(args) == 3 && args[0] == "check", len(args) == 4 && args[0] == "download":
		id, err := strconv.ParseInt(args[2], 10, 64)
		if err != nil || id < 1 {
			return errors.New("invalid App Store ID")
		}
		app.ID = id
	default:
		return errors.New("invalid Store SDK operation or arguments")
	}
	session, err := restoreStore(args[1])
	if err != nil {
		return err
	}
	switch args[0] {
	case "download-stream":
		return session.downloadStream(os.Stdin, os.Stdout, args[2])
	case "check":
		err = session.check(app)
	case "download":
		err = session.downloadIPA(app, args[3])
	}
	if err != nil {
		return err
	}
	return session.save(args[1])
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
