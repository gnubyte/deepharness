import Foundation

// MARK: - Permissions

/// The IAM permissions the app's Bedrock setup and chat use, as a policy an AWS administrator can
/// attach to the person (or their role).
public enum BedrockPermissions {
    /// Calling a model: Converse is authorized by InvokeModel, ConverseStream by
    /// InvokeModelWithResponseStream (there are no separate Converse actions).
    public static let invokeActions: [String] = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]

    /// The AWS managed policy that lets an identity use `aws login`.
    public static let signInManagedPolicy = "SignInLocalDevelopmentAccess"

    /// Least privilege for DSH: call models (directly or through cross-Region inference profiles,
    /// whose underlying models live in other Regions — and, for global profiles, in no Region, which
    /// the empty-matching "*" covers); list models and check access; accept Marketplace terms and the
    /// Anthropic form; Bedrock API keys; let Bedrock (and only Bedrock, aws:CalledViaLast) subscribe to
    /// Marketplace models; and `aws login`'s own two actions. An administrator can narrow the
    /// Marketplace statement further with aws-marketplace:ProductId.
    public static let policyJSON = """
        {
          "Version": "2012-10-17",
          "Statement": [
            {
              "Sid": "VisionCallBedrockModels",
              "Effect": "Allow",
              "Action": [
                "bedrock:InvokeModel",
                "bedrock:InvokeModelWithResponseStream"
              ],
              "Resource": [
                "arn:aws:bedrock:*::foundation-model/*",
                "arn:aws:bedrock:*:*:inference-profile/*"
              ]
            },
            {
              "Sid": "VisionSetUpModelAccess",
              "Effect": "Allow",
              "Action": [
                "bedrock:ListFoundationModels",
                "bedrock:GetFoundationModel",
                "bedrock:GetFoundationModelAvailability",
                "bedrock:ListInferenceProfiles",
                "bedrock:GetInferenceProfile",
                "bedrock:ListFoundationModelAgreementOffers",
                "bedrock:CreateFoundationModelAgreement",
                "bedrock:GetUseCaseForModelAccess",
                "bedrock:PutUseCaseForModelAccess"
              ],
              "Resource": "*"
            },
            {
              "Sid": "VisionBedrockApiKeys",
              "Effect": "Allow",
              "Action": "bedrock:CallWithBearerToken",
              "Resource": "*"
            },
            {
              "Sid": "VisionMarketplaceSubscriptionsThroughBedrock",
              "Effect": "Allow",
              "Action": [
                "aws-marketplace:Subscribe",
                "aws-marketplace:ViewSubscriptions",
                "aws-marketplace:Unsubscribe"
              ],
              "Resource": "*",
              "Condition": {
                "StringEquals": {
                  "aws:CalledViaLast": "bedrock.amazonaws.com"
                }
              }
            },
            {
              "Sid": "VisionSignInWithAwsLogin",
              "Effect": "Allow",
              "Action": [
                "signin:AuthorizeOAuth2Access",
                "signin:CreateOAuth2Token"
              ],
              "Resource": "arn:aws:signin:*:*:oauth2/public-client/*"
            }
          ]
        }
        """

    /// What to tell the person who has to add the policy.
    public static let explanation: String =
        "DSH uses Amazon Bedrock with your own AWS sign-in. If AWS says you aren't allowed to do something, "
        + "send this policy to whoever manages your AWS account and ask them to attach it to you (or to the role you sign in with). "
        + "It lets DSH: call Bedrock models, including through cross-Region inference profiles; list the models in your Region and check "
        + "whether your account can use them; accept a model's terms and Anthropic's one-time use-case form when you choose to; "
        + "use a Bedrock API key; let Bedrock subscribe to AWS Marketplace models on your behalf (only through Bedrock); and sign in "
        + "from the AWS CLI with \"aws login\" (the same as the AWS managed policy SignInLocalDevelopmentAccess). "
        + "It doesn't allow creating, changing or deleting anything else in the account."
}
