#import "BasecampNextAccount.h"
#import "OAuth2Token.h"

#define BASECAMP_NEXT_OAUTH_KEY @"ddb287c5f0f3d6ec0dbc0ee708a733b6506621d8"
#define BASECAMP_NEXT_OAUTH_SECRET @"32e106ca8eac91f0afc407d309ed436176f1bc3d"
#define BASECAMP_NEXT_REDIRECT @"feedsapp%3A%2F%2Fbasecampnext%2Fauth"

@implementation BasecampNextAccount

+ (void)load { [Account registerClass:self]; }
+ (BOOL)requiresAuth { return YES; }
+ (BOOL)requiresDomain { return NO; }
+ (BOOL)requiresUsername { return NO; }
+ (BOOL)requiresPassword { return NO; }
+ (NSString *)friendlyAccountName { return @"Basecamp"; }

- (void)beginAuth {
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://launchpad.37signals.com/authorization/new?client_id=%@&redirect_uri=%@&type=web_server",BASECAMP_NEXT_OAUTH_KEY, BASECAMP_NEXT_REDIRECT]];

    [[NSWorkspace sharedWorkspace] openURL:URL];
}

- (void)authWasFinishedWithURL:(NSURL *)url {
    NSLog(@"GOT URL: %@", url);

    // We could get:
    // feedsapp://basecampnext/auth?code=b1233f3e
    // feedsapp://basecampnext/auth?error=access_denied
    
    NSString *query = [url query]; // code=xyz
    
    if (![query beginsWithString:@"code="]) {
        
        NSString *message = @"There was an error while authenticating with Basecamp. Please try again later, or email support@feedsapp.com.";
        
        if ([query isEqualToString:@"error=access_denied"])
            message = @"Authorization was denied. Please try again.";
        
        [self.delegate account:self validationDidFailWithMessage:message field:AccountFailingFieldAuth];
        return;
    }
    
    NSArray *parts = [query componentsSeparatedByString:@"="];
    NSString *code = [parts objectAtIndex:1]; // xyz
  
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://launchpad.37signals.com/authorization/token?type=web_server&client_id=%@&redirect_uri=%@&client_secret=%@&code=%@",BASECAMP_NEXT_OAUTH_KEY,BASECAMP_NEXT_REDIRECT,BASECAMP_NEXT_OAUTH_SECRET,code]];
    
    NSMutableURLRequest *URLRequest = [NSMutableURLRequest requestWithURL:URL];
    URLRequest.HTTPMethod = @"POST";

    self.request = [SMWebRequest requestWithURLRequest:URLRequest delegate:nil context:NULL];
    [request addTarget:self action:@selector(tokenRequestComplete:) forRequestEvents:SMWebRequestEventComplete];
    [request addTarget:self action:@selector(tokenRequestError:) forRequestEvents:SMWebRequestEventError];
    [request start];
}

- (void)tokenRequestComplete:(NSData *)data {

    NSString *error = nil;
    OAuth2Token *token = [[[OAuth2Token alloc] initWithTokenResponse:data error:&error] autorelease];
    
    if (token) {
        [self validateWithPassword:token.stringRepresentation];
    }
    else {
        NSString *message = [NSString stringWithFormat:@"There was an error while authenticating with Basecamp: \"%@\"", &error];
        [self.delegate account:self validationDidFailWithMessage:message field:AccountFailingFieldAuth];
    }
}

- (void)tokenRequestError:(NSError *)error {
    [self.delegate account:self validationDidFailWithMessage:@"There was an error while authenticating with Basecamp. Please try again later, or email support@feedsapp.com." field:AccountFailingFieldAuth];
}

- (void)validateWithPassword:(NSString *)password {

    NSString *URL = @"https://launchpad.37signals.com/authorization.json";
    OAuth2Token *token = [OAuth2Token tokenWithStringRepresentation:password];
    
    NSURLRequest *URLRequest = [NSURLRequest requestWithURLString:URL OAuth2Token:token];
    
    self.request = [SMWebRequest requestWithURLRequest:URLRequest delegate:nil context:password];
    [request addTarget:self action:@selector(authorizationRequestComplete:password:) forRequestEvents:SMWebRequestEventComplete];
    [request addTarget:self action:@selector(handleGenericError:) forRequestEvents:SMWebRequestEventError];
    [request start];
}

- (void)authorizationRequestComplete:(NSData *)data password:(NSString *)password {
    
    NSDictionary *response = [data objectFromJSONData];
    
    NSDictionary *identity = [response objectForKey:@"identity"];
    NSString *author = [[identity objectForKey:@"id"] stringValue];
    
    // update our "username" with our author name - this will cause our account to look nice in the list.
    self.username = [NSString stringWithFormat:@"%@ %@", [identity objectForKey:@"first_name"] ?: @"", [identity objectForKey:@"last_name"] ?: @""];
    
    NSArray *accounts = [response objectForKey:@"accounts"];
    
    NSMutableArray *foundFeeds = [NSMutableArray array];

    for (NSDictionary *account in accounts) {
        
        NSString *product = [account objectForKey:@"product"];
        if ([product isEqualToString:@"bcx"]) { // basecamp next

            NSString *accountName = [account objectForKey:@"name"];
            NSString *accountIdentifier = [account objectForKey:@"id"];            
            NSString *accountFeedString = [NSString stringWithFormat:@"https://basecamp.com/%@/api/v1/events.json", accountIdentifier];
            
            Feed *feed = [Feed feedWithURLString:accountFeedString title:accountName author:author account:self];
            feed.requiresOAuth2Token = YES;
            [foundFeeds addObject:feed];
        }
    }
    
    self.feeds = foundFeeds;
    
    [self.delegate account:self validationDidCompleteWithPassword:password];
}

- (void)handleGenericError:(NSError *)error {
    NSLog(@"Error! %@", error);
    [self.delegate account:self validationDidFailWithMessage:@"Could not retrieve information about the given Basecamp account. Please contact support@feedsapp.com." field:0];
}

#pragma mark Refreshing Feeds and Tokens

- (void)refreshFeeds:(NSArray *)feedsToRefresh {

    // refresh our access_token first.
    NSString *password = self.findPassword;
    OAuth2Token *token = [OAuth2Token tokenWithStringRepresentation:password];

    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:@"https://launchpad.37signals.com/authorization/token?type=refresh&client_id=%@&client_secret=%@&grant_type=refresh_token&refresh_token=%@", BASECAMP_NEXT_OAUTH_KEY,BASECAMP_NEXT_OAUTH_SECRET,token.refresh_token.stringByEscapingForURLArgument]];
    
    NSMutableURLRequest *URLRequest = [NSMutableURLRequest requestWithURL:URL];
    URLRequest.HTTPMethod = @"POST";
    
    self.tokenRequest = [SMWebRequest requestWithURLRequest:URLRequest delegate:nil context:feedsToRefresh];
    [tokenRequest addTarget:self action:@selector(refreshTokenRequestComplete:feeds:) forRequestEvents:SMWebRequestEventComplete];
    [tokenRequest addTarget:self action:@selector(refreshTokenRequestError:) forRequestEvents:SMWebRequestEventError];
    [tokenRequest start];
}

- (void)refreshTokenRequestComplete:(NSData *)data feeds:(NSArray *)feedsToRefresh {
    
    NSString *password = self.findPassword;
    OAuth2Token *token = [OAuth2Token tokenWithStringRepresentation:password];
    NSString *error = nil;
    OAuth2Token *newToken = [[[OAuth2Token alloc] initWithTokenResponse:data error:&error] autorelease];

    if (newToken) {
        
        // absorb new token if necessary
        if (![newToken.access_token isEqualToString:token.access_token]) {
            token.access_token = newToken.access_token;
            [self savePassword:token.stringRepresentation];
            [Account saveAccountsAndNotify:NO]; // not a notification-worthy change
        }
        
        // NOW refresh feeds
        [super refreshFeeds:feedsToRefresh];
    }
    else NSLog(@"NO TOKEN: %@", [data objectFromJSONData]);
}

- (void)refreshTokenRequestError:(NSError *)error {
    NSLog(@"ERROR WHILE REFRESHING: %@", error);
}


// TODO: EXCHANGE REFRESH TOKENS, BLAH

// https://launchpad.37signals.com/authorization/token?type=refresh&client_id=ddb287c5f0f3d6ec0dbc0ee708a733b6506621d8&client_secret=32e106ca8eac91f0afc407d309ed436176f1bc3d&grant_type=refresh_token&refresh_token=BAhbByIB/3siZXhwaXJlc19hdCI6IjIwMjItMDMtMzBUMTQ6MjQ6MjNaIiwidXNlcl9pZHMiOls4MTg3NDIsMjM5NzU3MCw1MjMxMTM3LDQwNzA3NDksODE1NzgzNiw4NDQzNDE2LDg1MTg0MjUsODUzMTAzNyw4NTMxMDU2LDg3OTY5NjksMTEwODQ4NTddLCJ2ZXJzaW9uIjoxLCJjbGllbnRfaWQiOiJkZGIyODdjNWYwZjNkNmVjMGRiYzBlZTcwOGE3MzNiNjUwNjYyMWQ4IiwiYXBpX2RlYWRib2x0IjoiNDg3NTk1OTJmMTQzNDVlMTQ1MDM3ZTM3ZTk5MzM5YWIifXU6CVRpbWUNzosewJD0cmE=--8955445c46abc2e0e5abf423a9f171a97d595e52

// TODO: USE SINCE-DATE

#pragma mark Parsing Response

+ (NSArray *)itemsForRequest:(SMWebRequest *)request data:(NSData *)data domain:(NSString *)domain username:(NSString *)username password:(NSString *)password {
    if ([request.request.URL.host isEqualToString:@"basecamp.com"]) {
        
        OAuth2Token *token = [OAuth2Token tokenWithStringRepresentation:password];
        
        // first we have to know who *we* are, and our author ID is different for each basecamp account (of course).
        // so we'll look it up if needed.
        NSURL *authorLookup = [NSURL URLWithString:@"people/me.json" relativeToURL:request.request.URL];
        NSData *authorData = [self extraDataWithContentsOfURLRequest:[NSMutableURLRequest requestWithURL:authorLookup OAuth2Token:token]];
        NSDictionary *response = [authorData objectFromJSONData];
        NSString *authorIdentifier = [[response objectForKey:@"id"] stringValue];
        
        NSMutableArray *items = [NSMutableArray array];

        NSArray *events = [data objectFromJSONData];
        
        for (NSDictionary *event in events) {
            
            NSString *date = [event objectForKey:@"created_at"];
            NSDictionary *bucket = [event objectForKey:@"bucket"];
            NSDictionary *creator = [event objectForKey:@"creator"];
            NSString *creatorIdentifier = [[creator objectForKey:@"id"] stringValue];

            NSString *URL = [event objectForKey:@"url"];
            URL = [URL stringByReplacingOccurrencesOfString:@"/api/v1/" withString:@"/"];
            URL = [URL stringByReplacingOccurrencesOfString:@".json" withString:@""];

            FeedItem *item = [[FeedItem new] autorelease];
            item.rawDate = date;
            item.published = AutoFormatDate(date);
            item.updated = item.published;
            item.author = [creator objectForKey:@"name"];
            item.authoredByMe = [creatorIdentifier isEqualToString:authorIdentifier];
            item.content = [event objectForKey:@"summary"];
            item.project = [bucket objectForKey:@"name"];
            item.link = [NSURL URLWithString:URL];
//            item.title = [NSString stringWithFormat:@"%@ %@", item.author, item.content];
            [items addObject:item];
        }
        
        return items;
    }
    else return nil;
}

@end



//- (void)meRequestComplete:(NSData *)data token:(NSString *)token {
//
//    NSDictionary *response = [data objectFromJSONData];
//    NSString *author = [[response objectForKey:@"id"] stringValue]; // store author by unique identifier instead of name
//
//    //NSString *URL = [NSString stringWithFormat:@"https://basecamp.com/%@/api/v1/projects.json", domain];
//    NSString *URL = @"https://launchpad.37signals.com/authorization.json";
//
//    NSURLRequest *URLRequest = [NSURLRequest requestWithURLString:URL bearerToken:token];
//
//    NSArray *context = [NSArray arrayWithObjects:token, author, nil];
//    
//    self.request = [SMWebRequest requestWithURLRequest:URLRequest delegate:nil context:context];
//    [request addTarget:self action:@selector(projectsRequestComplete:) forRequestEvents:SMWebRequestEventComplete];
//    [request addTarget:self action:@selector(projectsRequestError:) forRequestEvents:SMWebRequestEventError];
//    [request start];
//}
//
//- (void)meRequestError:(NSError *)error {
//    NSLog(@"Error! %@", error);
//    if (error.code == 404)
//        [self.delegate account:self validationDidFailWithMessage:@"Could not find the given Basecamp account. Please verify that your Account ID matches the number found in your browser's address bar." field:AccountFailingFieldDomain];
//    else if (error.code == 500)
//        [self.delegate account:self validationDidFailWithMessage:@"There was a problem signing in to the given Basecamp account. Please check your username and password." field:0];
//    else
//        [self.delegate account:self validationDidFailWithMessage:error.localizedDescription field:AccountFailingFieldUnknown];
//}

//- (void)projectsRequestComplete:(NSData *)data context:(NSArray *)context {
//    
//    NSString *token = [context objectAtIndex:0];
//    NSString *author = [context objectAtIndex:1];
//
//    NSArray *projects = [data objectFromJSONData];
//    
//    NSString *mainFeedString = [NSString stringWithFormat:@"https://basecamp.com/%@/api/v1/events.json", domain];
//    NSString *mainFeedTitle = @"All Events";
//    Feed *mainFeed = [Feed feedWithURLString:mainFeedString title:mainFeedTitle author:author account:self];
//    mainFeed.requiresBearerToken = YES;
//    
//    NSMutableArray *foundFeeds = [NSMutableArray arrayWithObject:mainFeed];
//    
//    for (NSDictionary *project in projects) {
//        
//        NSString *projectName = [project objectForKey:@"name"];
//        NSString *projectIdentifier = [project objectForKey:@"id"];
//        NSString *projectFeedString = [NSString stringWithFormat:@"https://basecamp.com/%@/api/v1/projects/%@/events.json", domain, projectIdentifier];
//        NSString *projectFeedTitle = [NSString stringWithFormat:@"Events for project \"%@\"", projectName];
//        Feed *projectFeed = [Feed feedWithURLString:projectFeedString title:projectFeedTitle author:author account:self];
//        projectFeed.requiresBearerToken = YES;
//        projectFeed.disabled = YES; // disable by default, only enable All Events
//        [foundFeeds addObject:projectFeed];
//    }
//    
//    self.feeds = foundFeeds;
//    
//    [self.delegate account:self validationDidCompleteWithPassword:token];
//}
