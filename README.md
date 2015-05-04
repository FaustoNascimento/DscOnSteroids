# DscOnSteroids
A proof of concept demonstrating some potential improvements that can be achieved when building DSC resources

When developing some DSC resources I noticed a few areas that could be improved and started working on ways to attempt to fix them.

Some of these  areas were rather easy to improve, while others required a bit more imagination and others raised more questions than they closed :)

So, let's start with looking at some of the easy to get out of the way improvements:

**- ConfigurationMode settings directly on the DSC resource**

What does this mean? Well, normally there's just a single ConfigurationMode that is defined at the LCM level. You can set it to ApplyOnce, ApplyAndMonitor and ApplyAndAutoCorrect. 
But, what if you want some configuration items to be on one configuration mode and others on another one?

This DSC resource addresses that by bringing ConfigurationMode directly to the DSC resource as a DscProperty.

This allows for very flexibly and complex configurations, imagine for example this one:

You have a completely automated method for creating AD users using DSC. For the sake of simplicity, let's say that an AD user only has the following attributes: sAMAccountName, displayName, mail, telephoneNumber, department, distinguishedName.

You create a DSC configuration item to create the AD user and you pass all of the possible user attributes. You don't want to correct drifts on all of the attributes - for example a user might get moved to a different department, get a new telephone number, get married and request a displayName change, be moved to a different OU -, so you set this configuration item to ApplyOnce or ApplyAndMonitor.

However, there might be other properties that you want to ensure never change and if they do rely on DSC to bring them back to the desired state. So you create a second configuration item with the properties mail, sAMAccountName, mail and set this second configuration item to ApplyAndAutoCorrect.

The method I developed allows you to do that!

**NOTE:** The LCM client has absolutely no idea of what we're doing and this is completely independant from the LCM client. As such, the LCM client **must** be set to ApplyAndAutoCorrect for DSC resources that implement this feature to work properly.

**- ConfigurationModeFrequencyMins settings directly on the DSC resource**

This is directly related to the ConfigurationMode and it defines how often a configuration item should be evaluated. If you have some configuration items that you don't want to run as often as the others, just set the ConfigurationModeFrequencyMins value to something higher.

This value needs to be a multiple of the ConfigurationModeFrequencyMins value defined in the LCM client. Again the LCM client has no knowledge of what we're doing.

**- Tracking drifts to the DSC's key property**

Every DSC resource requires a unique identifier to be specified, a key that tells it which object to look for. The problem is in some cases that property is not unique, or is read/write.

Imagine the following scenario: You have a DSC configuration item which creates an IIS website named 'HelloWorld' (unique identifier) and binds it to port 80. On a ApplyAndAutoCorrect configuration mode, if the site is deleted, DSC will recreate it (as it should). But what happens if the unique identifier of the website as far as DSC is concerned changes?
In other words, what happens if I manually change the website's name to 'GoodbyeWorld'? When DSC next runs, all it will see is that there is no website called 'HelloWorld', and it will attempt to create one. When it comes to the bindings stage it will fail since port 80 is already assigned to website 'GoodbyeWorld'.

Bearing in mind that the website's name is a writeable property, shouldn't DSC check for drifts on that as well? Shouldn't DSC be able to find the webite called 'GoodbyeWorld' and rename it back to 'HelloWorld' as per the specified configuration?

The 'simple' solution would be to ensure that the resource uses the unique identifier of the object its managing. In the example above, that would be the unique identifier for the IIS website. 
But there are too many problems with this: most often this is a rather hard to read string or a GUID, mistakes can happen when writing it. Isn't part of the idea behind DSC to automate and eliminate human error?
Also, this would never really work. If instead of using a website name as the DSC resource's key property I used a GUID for example, DSC would check if an object (website in this case) with that GUID existed. If it didn't, it would attempt to create one and assign it that GUID, but the GUID is not something that can be specified for many objects, it's something the system picks automatically internally.
Even if it was possible to specify it, in some cases the object is never really deleted so the GUID can't be re-used, which DSC would require.

So my solution creates and internally maintains a mapping table between the name the user provides, and the real unique ID for that object. If the object is re-created for whatever reason, the mapping table is updated. If there is an entry on the mapping table and the object's name changes, since we have the unique identifier (which cannot be written) we'll be able to track and retrieve the object - and most importantly set its name back to what it should be!

**- Improved Test and Set functionality**

Traditionally, a DSC resource was built so that the Test() would perform tests until one failed, at which point it would immediately stop processing any other tests and immediately return a $false. LCM would then interpret the $false as 'the configuration is not OK' and call the Set() to correct it.

The logic behind this is to 'fail early', preventing non-required tests from being run. However this logic is slightly flawed.

There are two problems with this approach:
- First, the Set() has no idea what tests the Test() had already successfully completed, so it will need to perform all tests again.
- Because the Set() has no ideas which tests the Test() has already performed, in many cases tests will be run twice

Imagine the following scenario: using our AD user from the example above, we established 5 tests for it mail, telephoneNumber, displayName, department, distinguishedName (OU).

The Test() starts running and performs the first test: is mail correct? The answer is yes, so it moves to the second test: is telephoneNumber correct? This is also true, so it moves to the next test: is displayName correct? No. It fails on this test, so it immediately returns a $false and doesn't process any other tests (fail early)

The Set() starts and it knows it needs to fix 'something'. The question is what? So, it starts performing exactly the same tests as the Test() did, resulting in duplication of tests: is the telephoneNumber correct? Yes ... bla bla bla. When it finds that the displayName is incorrect, it corrects it, but it could still be that other attributes could also need correcting - after all the Test() failed early and there is no information passed between the Set() and Test()... So Set() needs to run the remaining tests too.

Now imagine that each test takes 5 seconds to run (ensuring SQL is properly installed, correct permissions, database access etc... is a good example of something that could take time). By running tests multiple times, we're severely increating the amount of time the configuration item takes to run.

On top of some tests being run multiple times, this also demonstrates something else: there is no benefit in 'failing early'. **All tests** will always need to be run. If no tests fail the Test() will run all tests. If **any** tests fail, regardless of how early or how late into the process, all tests will be run by the Set(), on top of the tests that had already been run by the Test().

So, why no separate the two? Have the Test() perform **all** tests, regardless of how many fail, gathering a list of things that need fixing, and then passing that to the Set()? The Set() just needs to know what to fix, it's a Setter, not a Tester and a Setter.

As was highlighted by Jaykul, what about if the machine's configuration changes in between the Test() running its tests and the Set() being called? It could be that the Set() is being told to run operations that are no longer required. Or not told to run operations that are required.

This is a very good point, but not something that really matters much here. First of all one of the main features of DSC is fixing drifts (if you're not interested in using DSC to fix drifts this doesn't affect you either way). This means that if a drift can't be fixed on a first pass, it will be re-tried again in a short amount of time.

I agree this is not a great answer, as it could be the difference between a system being offline for 30m or not and 30m could cost A LOT of money. But then let me ask you this: how does the current method prevent this from happening anyway? If you run 10 tests, you're now on the 9th test and so far all tests returned $true, what's to prevent the configuration of whatever the first test tests for from changing? The only thing preventing it from doing so is the short amount of time in between tests. 
And while I painted a very grim picture with each test taking 5 seconds to run, that's barely ever the case. This particular resource runs about 10 tests and they run in 0.5 seconds most of the times, with the Set() running in about 4-5 seconds (depending on what needs to be set). That gives you a window of less than 10 seconds every 30m (assuming defaults) to 'screw things up'. And even then, after 30m it will automatically fix itself.

These are indeed good questions that should be raised, but not something that is limited to this DSC resource or the way I'm proposing things be done, it's a much bigger thing than that.

Either way, the improvement here is that all tests will be performed by the Test() and it will pass a list of things to fix to the Set(). The Set() will just 'blindly' follow what the Test() told it to do, it makes no verifications of any kind, it just 'gets it done'.

By doing this, it opened up the doors to a lot of other possibilities too. If you think about it, there are (normally) 4 types of cmdlets one might want to call when writing a DSC resource:

New-<object>
Remove-<object>
Set-<object>
Rename-<object>

There are slight variations of these, but mostly they come down to that. For example in this module there are properties that can only be set when the switch is being created. So if the switch already exists but we need to set that property, we need to re-create the switch.
What is a recreate?

Call the Delete-<object> and the New-<object>. Done. Just pass two instructions to the Set() and it will do it in the order the instructions are provided.

Want to be a bid wild and call it the other way around? New-<Object> and Delete-<Object>? Hey, you're the boss! It will be done.

Want to set some properties on the object and then rename it? Sure, just tell the Test() to pass this to the Set(): Set-<Object> and then Rename-<Object>

Some properties that can't be set when creating the object (this resource showcases a few of those)? Just call New-<Object> and then Set-<Object>, not a problem. And if you really want to... add a Delete-<Object> after. Basically the Set() receives a list of instructions and it processes them on a First-In-First-Out manner.

Another thing that can be done (which might not be adviseable for every single resource, but I've done here to showcase it) is calling multiple Set-<Object>s instead of just one with all properties to be set.

Call Set-<Object> -SwitchType Internal as one call, and then Set-<Object> -Notes 'Hello, I was created by a script' in another call. Is it slower? Sure. Does it provide a lot more flexibility? Definitely! Is it always worth using this? No. It needs to be evaluated on a case-by-case scenario.

**And last, but not least...**

I tried to separate the code blocks of Set(), Get() and Test() in a way that they are completely agnostic to the DSC resource. In other words, you could just copy paste them to a new resource and they'd never need to change (obviously this assumes the functions they call and variables they rely on exist but I tried to avoid calling variables that are specific to a DSC resource on them).

I'm hoping that this will allow for some standardisation of how DSC Resources are made going forward.


**NOTES**

Everything I posted here is a work in progress and far far from complete. At this stage I am hoping to get some feedback on how to improve what the groundwork I created, add new features, correct the code or provide improvements to it (running faster, easier to read, whatever). Then we'll see where that takes us :)

Fausto Nascimento
